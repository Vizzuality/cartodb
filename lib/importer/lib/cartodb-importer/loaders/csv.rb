
module CartoDB
  module Import
    class CSV < CartoDB::Import::Loader

      register_loader :csv
      register_loader :txt

      def process!
        @data_import = DataImport.find(:id=>@data_import_id)

        if File.extname(@path) == '.txt'
          File.rename(@path, "#{@path}.csv")
          @path = "#{@path}.csv"
        end

        # run Chardet + Iconv
        fix_encoding
        
        # Check if file has only one header, add a blank column
        # if so. See Vizzuality/CartoDB#202
        headers = File.open("#{@path}") {|f| f.readline}
        unless headers =~ /[\,\;]/
          `sed -ie "1 s/$/;/" #{@path}`
        end

        @data_import.log_update("ogr2ogr #{@suggested_name}")
        ogr2ogr_bin_path = `which ogr2ogr`.strip
        ogr2ogr_command = %Q{#{ogr2ogr_bin_path} -f "PostgreSQL" PG:"host=#{@db_configuration[:host]} port=#{@db_configuration[:port]} user=#{@db_configuration[:username]} dbname=#{@db_configuration[:database]}" #{@path} -nln #{@suggested_name}}
        
        stdin,  stdout, stderr = Open3.popen3(ogr2ogr_command) 
  
        unless (err = stderr.read).empty?
          if err.downcase.include?('failure')
            @data_import.set_error_code(3006)
            @data_import.log_error(err)
            @data_import.log_error("ERROR: failed to import #{@ext.sub('.','')} to database")
            if err.include? "already exists"
              @data_import.set_error_code(5002)
              @data_import.log_error("ERROR: #{@path} contains reserved column names")
            end
            #raise "failed to import #{@ext.sub('.','')} to database"
          else
            @data_import.log_update(err)
          end
        end
        
        unless (reg = stdout.read).empty?
          @runlog.stdout << reg
        end

        # Check if the file had data, if not rise an error because probably something went wrong
        begin
          row = @db_connection["SELECT * from #{@suggested_name} LIMIT 1"]
        rescue Exception => e
          @runlog.err << "Empty table"
          @data_import.set_error_code(3006)
          @data_import.log_error(err)
          @data_import.log_error("ERROR: failed to import #{@ext.sub('.','')} to database")
          raise "failed to import table"
        end
        if row.first.nil?
          @runlog.err << "Empty table"
          @data_import.set_error_code(5001)
          @data_import.log_error(err)
          @data_import.log_error("ERROR: no data could be imported from file")
          raise "empty table"
        end

        # Importing CartoDB CSV exports
        # ===============================
        # * if there is a column already called the_geom
        # * if there is geojson in it
        # * rename column to the_geom_orig
        # * create a new column with the correct type (Assume 4326) "the_geom_temp"
        # * loop over table and parse geojson into postgis geometries
        # * drop the_geom_orig
        #
        column_names = @db_connection.schema(@suggested_name).map{ |s| s[0].to_s }
        if column_names.include? "the_geom"
          @data_import.log_update("update the_geom")
          if res = @db_connection["select the_geom from #{@suggested_name} WHERE the_geom is not null and the_geom != '' limit 1"].first

            # attempt to read as geojson. If it fails, continue
            begin
              geojson       = RGeo::GeoJSON.decode(res[:the_geom], :json_parser => :json)
              geometry_type = geojson.geometry_type.type_name.upcase

              if geometry_type
                # move original geometry column around
                @db_connection.run("ALTER TABLE #{@suggested_name} RENAME COLUMN the_geom TO the_geom_orig;")
                @db_connection.run("SELECT AddGeometryColumn('#{@suggested_name}','the_geom',4326, '#{geometry_type}', 2)")
                @db_connection.run("CREATE INDEX #{@suggested_name}_the_geom_gist ON #{@suggested_name} USING GIST (the_geom)")

                # loop through old geom parsing into the_geom.
                # TODO: Replace with ST_GeomFromGeoJSON when production has been upgraded to postgis r8692
                # @db_connection.run("UPDATE #{@suggested_name} SET the_geom = ST_SetSRID(ST_GeomFromGeoJSON(the_geom_orig),4326) WHERE the_geom_orig IS NOT NULL")
                # tokumine ticket: http://trac.osgeo.org/postgis/ticket/1434
                @data_import.log_update("converting GeoJSON to the_geom")
                @db_connection["select the_geom_orig from #{@suggested_name} where the_geom_orig != '' and the_geom_orig is not null "].each do |res|
                  begin
                    geojson = RGeo::GeoJSON.decode(res[:the_geom_orig], :json_parser => :json)
                    if geojson
                      @db_connection.run("UPDATE #{@suggested_name} SET the_geom = ST_GeomFromText('#{geojson.as_text}', 4326) WHERE the_geom IS NULL AND the_geom_orig = '#{res[:the_geom_orig]}';");
                    end
                  rescue => e
                    @runlog.err << "silently fail conversion #{geojson.inspect} to #{@suggested_name}. #{e.inspect}"
                    @data_import.log_error("ERROR: silently fail conversion #{geojson.inspect} to #{@suggested_name}. #{e.inspect}")
                  end
                end
                # Drop original the_geom column
                @db_connection.run("ALTER TABLE #{@suggested_name} DROP COLUMN the_geom_orig")
              end
            rescue => e
              column_names.delete('the_geom')
              @db_connection.run("ALTER TABLE #{@suggested_name} RENAME COLUMN the_geom TO invalid_the_geom;")
              @runlog.err << "failed to read geojson for #{@suggested_name}. #{e.inspect}"
              @data_import.log_error("ERROR: failed to read geojson for #{@suggested_name}. #{e.inspect}")
            end
          else
            begin
              column_names.delete('the_geom')
              @db_connection.run("ALTER TABLE #{@suggested_name} RENAME COLUMN the_geom TO invalid_the_geom;")
            rescue
              column_names.delete('the_geom')
              @runlog.err << "failed to convert the_geom to invalid_the_geom"
              @data_import.log_error("ERROR: failed to convert the_geom to invalid_the_geom")
            end
          end
        end
        
        # if there is no the_geom, and there are latitude and longitude columns, create the_geom
        unless column_names.include? "the_geom"

          latitude_possible_names = "'latitude','lat','latitudedecimal','latitud','lati','decimallatitude','decimallat'"
          longitude_possible_names = "'longitude','lon','lng','longitudedecimal','longitud','long','decimallongitude','decimallon'"

          matching_latitude = nil
          res = @db_connection["select column_name from information_schema.columns where table_name ='#{@suggested_name}'
            and lower(column_name) in (#{latitude_possible_names}) LIMIT 1"]
          if !res.first.nil?
            matching_latitude= res.first[:column_name]
          end
          matching_longitude = nil
          res = @db_connection["select column_name from information_schema.columns where table_name ='#{@suggested_name}'
            and lower(column_name) in (#{longitude_possible_names}) LIMIT 1"]
          if !res.first.nil?
            matching_longitude= res.first[:column_name]
          end


          if matching_latitude and matching_longitude
              @data_import.log_update("converting #{matching_latitude}, #{matching_latitude} to the_geom")
              #we know there is a latitude/longitude columns
              @db_connection.run("SELECT AddGeometryColumn('#{@suggested_name}','the_geom',4326, 'POINT', 2);")
              #TODO
              # reconcile the two matching_latitude regex below
              # the first one wasn't stringent enough, but i realize
              # the second one doesn't bother with absolute extent check
              @db_connection.run(<<-GEOREF
              UPDATE \"#{@suggested_name}\"
              SET the_geom =
                ST_GeomFromText(
                  'POINT(' || trim(\"#{matching_longitude}\") || ' ' || trim(\"#{matching_latitude}\") || ')', 4326
              )
              WHERE
              trim(CAST(\"#{matching_longitude}\" AS text)) ~ '^(([-+]?(([0-9]|[1-9][0-9]|1[0-7][0-9])(\.[0-9]+)?))|[-+]?180)$'
              AND
              trim(CAST(\"#{matching_latitude}\" AS text))  ~   
              '^(([-+]?(([0-9]|[1-8][0-9])(\.[0-9]+)?))|[-+]?90)$'
              GEOREF
              )
              
              @db_connection.run("CREATE INDEX \"#{@suggested_name}_the_geom_gist\" ON \"#{@suggested_name}\" USING GIST (the_geom)")
          end
        end

        begin
          # Sanitize column names where needed
          sanitize_table_columns @suggested_name
        rescue Exception => msg  
          @runlog.err << msg
          @data_import.log_update("ERROR: Failed to sanitize some column names")
        end
        
        
        @table_created = true
        @data_import.log_update("table created")
        FileUtils.rm_rf(Dir.glob(@path))
        rows_imported = @db_connection["SELECT count(*) as count from #{@suggested_name}"].first[:count]

        payload = OpenStruct.new({
                                :name => @suggested_name,
                                :rows_imported => rows_imported,
                                :import_type => @import_type,
                                :log => @runlog
                                })

        # construct return variables
        [to_import_hash, payload]
      end
    end
  end
end

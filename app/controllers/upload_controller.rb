# coding: UTF-8

class UploadController < ApplicationController

  if Rails.env.production? || Rails.env.staging?
    ssl_required :create
  end

  skip_before_filter :verify_authenticity_token
  before_filter :api_or_user_authorization_required
  skip_before_filter :check_domain

  def create
    begin
      temp_file = filename = filedata = nil

      case
      when params[:qqfile].present? && request.body.present?
        filename = params[:qqfile]
        filedata = request.body.read.force_encoding('utf-8')
      when params[:file].present?
        filename = params[:file].original_filename
        filedata = params[:file].read.force_encoding('utf-8')
      end

      random_token = Digest::SHA2.hexdigest("#{Time.now.utc}--#{filename.object_id.to_s}").first(20)

      FileUtils.mkdir_p(Rails.root.join('public/uploads').join(random_token))

      file = File.new(Rails.root.join('public/uploads').join(random_token).join(File.basename(filename)), 'w')
      file.write filedata
      file.close

      render :json => {:file_uri => file.path[/(\/uploads\/.*)/, 1], :success => true}
    rescue => e
      logger.error e
      logger.error e.backtrace
      head(400)
    end
  end

  def api_or_user_authorization_required
    api_authorization_required || login_required
  end
  private :api_or_user_authorization_required
end

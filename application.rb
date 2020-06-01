#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'sinatra/json'
require "sinatra/base"
require 'json'

require_relative 'lib/controllers/rest_endpoints.rb'

class MyApp < Sinatra::Application

#     #The helper json should use the default to_json method
#     set :json_encoder, :to_json

#     error do
#         e = request.env['sinatra.error']
#         Kernel.puts e.backtrace.join("\n")
#         'Application error'
#     end

#     helpers do
#         def error code, data
#             data = {:errors => data}
#             halt code, {'Content-Type' => 'application/json'}, data.to_json
#         end

#         #Get limit & offset parameter for using it in DataMapper
#         def slice
#             params[:limit] ||= 10
#             params[:offset] ||= 0
#             params[:limit] = params[:limit].to_i
#             params[:offset] = params[:offset].to_i

#             if params[:limit] < 0 or params[:limit] > 10
#                 error 400, "Invalid limit"
#             end
#             if params[:offset] < 0
#                 error 400, "Invalid offset"
#             end
#             {:limit => params[:limit], :offset => params[:offset]}
#         end

#         def protected!
#             unless authorized?
#                 response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
#                 throw(:halt, [401, "Not authorized\n"])
#             end
#         end

#         def authorized?
#             @auth ||=  Rack::Auth::Basic::Request.new(request.env)
#             if @auth.provided? && @auth.basic? && @auth.credentials
#                 @user = User.first(:email => @auth.credentials[0])
#                 #Datamapper include some magic for password we didn't store plain text password in DB
#                 if @user and @user.password == @auth.credentials[1]
#                     return true
#                 end
#             end
#             return false
#         end
#     end

#     before do
#         if request.env['CONTENT_TYPE'] !~ /multipart\/form-data/ #A file upload
#             #Transform JSON object in params
#             request.body.rewind  # in case someone already read it
#             data = request.body.read
#             if data.length > 0
#                 JSON.parse(data).each_pair do |key,value|
#                     params[key] = value
#                 end
#             end
#         end
#     end

#     # root page
#     get '/' do
#         halt [200, "Hello world"]
#     end

#     get '/me' do
#         protected!
#         json @user, :encoder => :to_json_private
#     end

    # require_relative "#{File.dirname(__FILE__)}/lib/controllers/rest_endpoints.rb"
#     # # load controllers
#     # $LOAD_PATH.unshift("#{File.dirname(__FILE__)}/lib/controllers")
#     # Dir.glob("#{File.dirname(__FILE__)}/lib/controllers/*.rb").each do |lib|
#     #     require_relative lib
#     # end

    # start the server if ruby file executed directly
    # run! if app_file == $0
end

# curl -k -X POST -H "X-username: p1:x" http://localhost:4567/api/tables/test
# curl -k -X POST -H "X-username: p2:x" http://localhost:4567/api/tables/test/join
# curl -k -X POST -H "X-username: p1:x" http://localhost:4567/api/tables/test/start
# curl -k -H "X-username: p2:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p1:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p2:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p1:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p2:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p1:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p2:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action
# curl -k -H "X-username: p1:x" --data-binary '{"what": "call"}' http://localhost:4567/api/tables/test/action

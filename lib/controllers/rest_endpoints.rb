class RestApi < Sinatra::Application

  get '/poll-events' do
  end

  get '/test' do
      halt [200, "Hello world test"]
  end
end

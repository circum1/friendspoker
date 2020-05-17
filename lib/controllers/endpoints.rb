class MyApp < Sinatra::Application
    get '/test' do
        halt [200, "Hello world test"]
    end
end

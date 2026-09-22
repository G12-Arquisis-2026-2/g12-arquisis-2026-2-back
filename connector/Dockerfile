FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update -qq && apt-get install -y procps build-essential

COPY Gemfile ./
RUN bundle install

COPY consumer.rb ./

CMD ["ruby", "consumer.rb"]
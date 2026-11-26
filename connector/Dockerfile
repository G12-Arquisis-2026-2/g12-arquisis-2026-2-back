FROM ruby:3.3-slim

WORKDIR /app

RUN apt-get update -qq && apt-get install -y procps build-essential

# con el lock, la imagen instala las mismas versiones que los tests (bunny 2.24.0, aws-sdk-states)
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local frozen true && bundle install

COPY consumer.rb ./
COPY lib/ ./lib/

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD ruby -e 'exit(Time.now - File.mtime("/tmp/connector_alive") < 30 ? 0 : 1)'

CMD ["ruby", "consumer.rb"]

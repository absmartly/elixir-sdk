# Build stage
FROM elixir:1.15-alpine AS build

# Install build dependencies
RUN apk add --no-cache build-base git

# Set working directory
WORKDIR /app

# Copy SDK first (context is parent dir, so elixir-sdk not ../elixir-sdk)
COPY elixir-sdk /app/elixir-sdk

# Copy wrapper (context is parent dir, so cross-sdk-tests/elixir-wrapper)
COPY cross-sdk-tests/elixir-wrapper /app/elixir-wrapper

# Set working directory to wrapper
WORKDIR /app/elixir-wrapper

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Get dependencies
RUN mix deps.get --only prod

# Compile the project
RUN MIX_ENV=prod mix compile

# Runtime stage
FROM elixir:1.15-alpine

RUN apk add --no-cache libgcc libstdc++

WORKDIR /app

# Copy compiled build
COPY --from=build /app /app

WORKDIR /app/elixir-wrapper

# Install hex and rebar in runtime (needed for mix)
RUN mix local.hex --force && \
    mix local.rebar --force

# Expose port
EXPOSE 3000

# Run the application
CMD ["mix", "run", "--no-halt"]

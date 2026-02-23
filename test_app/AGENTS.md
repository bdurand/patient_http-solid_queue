# Test App

This is a test web application used for testing the SolidQueue Async HTTP library.

The code does not need unit tests or integration tests itself.

The code does not need to include YARD documentation comments.

The application can be started with `bundle exec rake test_app` and stopped with `bundle exec rake test_app:stop`. The port can be configured via the `PORT` environment variable (default: 9292).

It must only use CSS and Javascript bundled with the project and not rely on any external assets or CDNs.

## Coding style

Always include the `# frozen_string_literal: true` magic comment at the top of each ruby file.

Use `class << self` syntax for defining class methods. instead of `def self.method_name`. Class methods should come before the instance methods in the class definition.

All public methods should have YARD documentation. Include an empty comment line between the method description and the first YARD tag.

Private methods should be grouped together at the bottom of the class definition under a `private` keyword.

This project uses the standardrb style guide. Run `bundle exec standardrb --fix` to automatically fix style issues.
Code comments and documentation should be general, to the point, and age well. They should not reference ticket numbers, or conversations, or specific conditions you encountered and then fixed when building the code. Comments and documentation should be written using ASD-STE100 Simplified Technical English. The content should be evergreen and make sense when viewed later outside the context of our conversation or the environment where the code is currently running.

## Testing

Run the test suite with `bundle exec rspec`.

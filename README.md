# TrxExt

Extends functionality of ActiveRecord's transaction to auto-retry failed SQL transaction in case of deadlock, serialization error or unique constraint error. The implementation is not bound to any database, but relies on the rails connection adapters instead. Thus, if your database is supported by rails out of the box, then the gem's features will just work. Currently supported adapters:

- `postgresql`
- `mysql2`
- `sqlite3`
- `trilogy`

**WARNING!**

Because the implementation of this gem wraps some ActiveRecord methods - carefully test its integration into your project. For example, if your application patches ActiveRecord or if some of your gems patches ActiveRecord - there might be conflicts in the implementation which could potentially lead to the data loss.

## Requirements

- ActiveRecord 7.2+
- Ruby 3.1+

**If you need the support of rails v6.0, v6.1, v7.0 - please use v1.x of this gem, but it works with PostgreSQL only.**
**If you need the support of rails v7.1 - please use v2.x of this gem.**

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'trx_ext'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install trx_ext

## Usage

```ruby
require 'trx_ext'

# Object#trx is a shorthand of ActiveRecord::Base.transaction
trx do
  DummyRecord.first || DummyRecord.create
end

trx do
  DummyRecord.first || DummyRecord.create
  trx do |t|
    t.after_commit { puts "This message will be printed after COMMIT statement." }
  end  
end

trx do
  DummyRecord.first || DummyRecord.create
  trx do |t|
    t.after_rollback { puts "This message will be printed after ROLLBACK statement." }
  end
  raise ActiveRecord::Rollback
end

class DummyRecord
  # Wrap method in transaction
  wrap_in_trx def some_method_with_quieries
    DummyRecord.first || DummyRecord.create
  end
end
```

If you are using non-primary connection for your model - you have to explicitly call `trx` method over that class:

```ruby
DummyRecord.trx do
  DummyRecord.first || DummyRecord.create
end
```
In general, you should know about this if you are using multi-databases configuration.

If you want to wrap some method into a transaction using `wrap_in_trx` outside the ActiveRecord model context, you can pass a model name as a second argument explicitly:

```ruby
class MyAwesomeLib
  # Wrap method in transaction
  def some_method_with_quieries
    DummyRecord.first || DummyRecord.create
  end
  wrap_in_trx :some_method_with_quieries, 'DummyRecord'
end
```

## Configuration

```ruby
TrxExt.configure do |config|
  # Number of retries before failing when unique constraint error raises. Default is 5
  config.unique_retries = 5
end
```

## How it works?

When an ActiveRecord SQL query fails due to deadlock error, serialization error or unique constraint error - it is automatically retried. In case of ActiveRecord transaction - the block of code the AR transaction belongs to is re-executed, thus the transaction query is retried.

## Rules you have to stick when using this gem

**Don't put into a single transaction more than needed for integrity purposes.**

There is "On complete" feature that allows you to define callbacks(blocks of code) that will be executed after transaction is complete. See `On complete callbacks` section bellow for the docs. See `On complete callbacks integrity` section bellow to be aware about different situations with them.

* Don't explicitly wrap queries.

    #### Bad

    ```ruby
    trx { User.find_by(username: 'someusername') }
    ```

    #### Good

    ```ruby
    User.find_by(username: 'someusername')
    ```

* Don't wrap multiple `SELECT` queries in a single transaction unless it is of vital importance (see epigraph).

    #### Bad

    ```ruby
    trx do
      @author = User.first
      @posts = current_user.posts.load
    end
    ```

    ```sql
    BEGIN
    SELECT "users".* FROM "users" ...
    SELECT "posts".* FROM "posts" ...
    COMMIT
    ```

    #### Good

    ```ruby
    @author = User.first
    @posts = current_user.posts.load
    ```

    ```sql
    -- TrxExt::Retry.with_retry_until_serialized {
    SELECT "users".* FROM "users" ...
    -- }
    -- TrxExt::Retry.with_retry_until_serialized {
    SELECT "posts".* FROM "posts" ...
    -- }
    ```

* Beware of `AR::Relation` lazy loading if it is necessary to have multiple `SELECT`s in a single transaction.

    #### Bad

    ```ruby
    trx do
      @posts = Post.all
      @users = User.all
    end
    ```

    will result in no query.

    #### Good

    ```ruby
    trx do
      @posts = Post.all.load
      @users = User.all.load
    end
    ```

    ```sql
    BEGIN
    SELECT "posts".* FROM "posts" ...
    SELECT "users".* FROM "users" ...
    COMMIT
    ```

* When performing `UPDATE`/`INSERT` queries that depend on record's state - reload that record in the beginning of `trx` block.

  #### Bad
    ```ruby
    def initialize(user)
      @user = user  
    end

    def update_posts
      trx do
        @user.posts.update_all(banned: true) if @user.user_permission.admin?
      end  
    end    
    ```

    ```sql
    BEGIN      
      UPDATE posts SET banned = TRUE WHERE posts.user_id IN (...)
    COMMIT
    ```

  #### Explanation
  It might not be obvious that this code depends on `@user` - `UserPermission#admin?` is used to detect whether `Post#banned` must be updated. However, it is accessed through `@user` and there is no guarantee that, when calling `@user.user_permission`, it was not already cached by either previous calls, upper by stack trace, or inside `trx` block on transaction retry. This is why it is mandatory to call `@user.reload` - to reset user's cache and the cache of user's relations.

  #### Good
    ```ruby
    def initialize(user)
      @user = user  
    end
  
    def update_posts
      trx do
        @user.reload
        @user.posts.update_all(banned: true) if @user.user_permission.admin?
      end  
    end    
    ```

    ```sql
    BEGIN
      SELECT * FROM users WHERE users.id = ...
      SELECT * FROM user_permissions WHERE user_permissions.user_id = ...
      UPDATE posts SET banned = TRUE WHERE posts.id IN (...)
    COMMIT
    ```

* It may happen that you need to invoke mailer's method inside `trx` block and pass there values that are calculated within the transaction block. Normally, you need to extract those values into after-transaction code and invoke mailer after transaction's end. Use `after_commit` callback to simplify your code:

  #### Bad
    ```ruby
    trx do
      user = User.find_or_initialize_by(email: email)
      if user.save
        # May be invoked more than one time if transaction is retried
        Mailer.registration_confirmation(user.id).deliver_later 
      end
    end
    ```

  #### Good (before refactoring)
    ```ruby
    user = nil
    result = 
      trx do
        user = User.find_or_initialize_by(email: email)
        user.save
      end
    Mailer.registration_confirmation(user.id).deliver_later if result
    ```

  #### Good (after refactoring)
    ```ruby
    trx do |t|
      user = User.find_or_initialize_by(email: email)
      if user.save
        t.after_commit { Mailer.registration_confirmation(user.id).deliver_later }
      end
    end
    ```

* Always keep in mind, that retrying of transactions is just re-execution of ruby's block of code on transaction retry. If you have any variables, that are changing inside the block - ensure that their values are reset in the beginning of block. Don't use methods that will raise error if called more than twice.

  #### Bad
    ```ruby
    resurrected_users_count = 0
    trx do
      User.deleted.find_each do |user|
        if user.created_at > 2.days.ago
          user.active!
          resurrected_users_count += 1
        end
      end
    end
    puts resurrected_users_count
    ```

  #### Good
    ```ruby
    resurrected_users_count = nil
    trx do
      resurrected_users_count = 0
      User.deleted.find_each do |user|
        if user.created_at > 2.days.ago
          user.active!
          resurrected_users_count += 1
        end
      end
    end
    puts resurrected_users_count
    ```

  #### Bad
    ```ruby
    class UsersController
      def update
        # This may raise AbstractController::DoubleRenderError if either redirect or render invoked twice
        trx do
          if @user.update(user_params)
            redirect_to @user
          else
            render :edit
          end
        end
      end
    end
    ```

  #### Bad
    ```ruby
    class UsersController
      # This may raise AbstractController::DoubleRenderError if either redirect or render invoked twice
      wrap_in_trx def update
        if @user.update(user_params)
          redirect_to @user
        else
          render :edit
        end
      end
    end
    ```

  #### Good
    ```ruby
    class UsersController
      def update
        if @user.update(user_params)
          redirect_to @user
        else
          render :edit
        end
      end
    end
    ```

  #### Good
    ```ruby
    class UsersController
      def update
        trx do |t|
          if @user.update(user_params)
            t.after_commit { redirect_to @user }
          else
            t.after_commit { render :edit }
          end
        end
      end
    end
    ```

* Carefully implement the code that is related to the non-relational databases like Redis or MongoDB

  #### Bad
    ```ruby
    trx do
      @post.reload
      if @post.tags_arr.include?('special')
        @post.update_columns(special: true)
        @post.mongo_post.update(special: true)
      end  
    end
    ```

  #### Explanation

  Example: `@post.tags_arr.include?('special') == true` and, as a result, `@post.mongo_post.update(special: true)` is executed but transaction is failed to be serialized. On second try - `@post.tags_arr.include?('special')` becomes false but the value of `MongoPost#special` was already changed

  #### Good
    ```ruby
    trx do
      @post.reload
      if @post.tags_arr.include?('special')
        @post.update_columns(special: true)
      end
      @post.mongo_post.update(special: @post.tags_arr.include?('special'))
    end
    ```

* Don't explicitly use `return` in the transaction's block of code. It may affect on how the transaction is going to be finished. Currently, it finishes with `COMPLETE` statement, but in the future versions it may change - according to the [warning message](https://github.com/rails/rails/blob/v6.1.3.2/activerecord/lib/active_record/connection_adapters/abstract/transaction.rb#L330-L337), the behaviour may change soon.

  #### Bad
    ```ruby
    def some_method
      trx do 
        return if User.where(email: email).exists?
        
        User.create(email: email)
      end
    end
    ```

  #### Bad
    ```ruby
    def some_method
      trx do |t|
        user = User.find_by(email: email)
        return user if user
        
        user = User.create(email: email)
        t.after_commit { Mailer.registration_confirmation(user.id).deliver_later }
      end
    end
    ```

  #### Explanation
  Using `return` in the `Proc`(a block of code is a `Proc`) will return from the stack call instead the return from the block of code. Example:

    ```
    def some_method
      puts "Start"
      yield
      puts "End"
    end
  
    def another_method
      some_method do
        puts "Hi"
        return
      end
    end
    ```
  Calling `#another_method` will output `Start` and `Hi` string, `End` string will never get output. Refer to [official docs](https://ruby-doc.org/core-3.0.1/Proc.html#class-Proc-label-Lambda+and+non-lambda+semantics) for more info.

  #### Good
    ```ruby
    def some_method
      trx do 
        unless User.where(email: email).exists?
          User.create(email: email)
        end
      end
    end
    ```
  
  #### Good  
    ```ruby
    wrap_in_trx def some_method
      return if User.where(email: email).exists?
        
      User.create(email: email)
    end
    ```

  #### Good
    ```ruby
    wrap_in_trx def some_method
      user = User.find_by(email: email)
      return user if user
      
      user = User.create(email: email)
      trx { |t| t.after_commit { Mailer.registration_confirmation(user.id).deliver_later } }
    end
    ```

## Make methods atomic.

You can make any method atomic by wrapping it into transaction using `#wrap_in_trx`. Example:

```ruby
class ApplicationRecord < ActiveRecord::Base
  class << self
    wrap_in_trx :find_or_create_by
    wrap_in_trx :find_or_create_by!
  end

  wrap_in_trx def some_method
    SomeRecord.first || SomeRecord.create
  end
end
```

## Development

### Setup

- After checking out the repo, run `bundle install` to install dependencies.
- Run docker-compose using `docker compose up` command - it starts necessary services
- Run next command to create dev and test databases:

```shell
bundle exec rails db:create db:migrate
RAILS_ENV=test bundle exec rails db:migrate
```
    
Now you can run `bin/console` for an interactive prompt that will allow you to experiment.

### Tests

You can run tests for currently installed AR using `rspec` command. There is `bin/test_all_ar_versions` executable that allows you to run tests within all supported AR versions.

### Other

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/intale/trx_ext. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/intale/trx_ext/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the TrxExt project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/intale/trx_ext/blob/master/CODE_OF_CONDUCT.md).

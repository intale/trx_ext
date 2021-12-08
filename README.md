# TrxExt

Extends functionality of ActiveRecord's transaction to auto-retry failed SQL transaction in case of deadlock, serialization error or unique constraint error. It also allows you to define `on_complete` callback that is being executed after SQL transaction is finished(either COMMIT-ed or ROLLBACK-ed).

Currently, the implementation only works for ActiveRecord PostgreSQL adapter. Feel free to improve it.

**WARNING!**

Because the implementation of this gem is a patch for `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` - carefully test its integration into your project. For example, if your project patches ActiveRecord or if some of your gems patches ActiveRecord - there might be conflicts in the implementation which could potentially lead to the data loss.

Currently, the implementation is tested for `6.0.4.1` and `6.1.4.1` versions of ActiveRecord(see [TrxExt::SUPPORTED_AR_VERSIONS](lib/trx_ext/version.rb))

## Requirements

- ActiveRecord 6+
- Ruby 3
- PostgreSQL 9.1+

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
require 'active_record'

# Object #trx is a shorthand of ActiveRecord::Base.transaction
trx do
  DummyRecord.first || DummyRecord.create
end

trx do
  DummyRecord.first || DummyRecord.create
  trx do |c|
    c.on_complete { puts "This message will be printed after COMMIT statement." }
  end  
end

trx do
  DummyRecord.first || DummyRecord.create
  trx do |c|
    c.on_complete { puts "This message will be printed after ROLLBACK statement." }    
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

## Configuration

```ruby
TrxExt.configure do |c|
  # Number of retries before failing when unique constraint error raises. Default is 5
  c.unique_retries = 5
end
```

## How it works?

Your either every single AR SQL query or whole AR transaction is retried whenever it throws deadlock error, serialization error or unique constraint error. In case of AR transaction - the block of code that the AR transaction belongs to is re-executed, thus the transaction is retried.

## Rules you have to stick when using this gem

> "Don't put more into a single transaction than needed for integrity purposes."
>
> — [PostgreSQL documentation]

Since `ActiveRecord::ConnectionAdapters::PostgreSQLAdapter` is now patched with `TrxExt::Retry.with_retry_until_serialized`, there's no need to wrap every AR query in a `trx` block to ensure integrity. Wrap code in an explicit `trx` block if and only if it can or does produce two or more SQL queries *and* it is important to run those queries together atomically.

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
      @posts = Post.all
      @users = User.all
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

* It may happen that you need to invoke mailer's method inside `trx` block and pass there values that are calculated within the transaction block. Normally, you need to extract those values into after-transaction code and invoke mailer after transaction's end. Use `on_complete` callback to simplify your code:

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
    trx do |c|
      user = User.find_or_initialize_by(email: email)
      if user.save
        c.on_complete { Mailer.registration_confirmation(user.id).deliver_later }   
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
        trx do |c|
          if @user.update(user_params)
            c.on_complete { redirect_to @user }
          else
            c.on_complete { render :edit }                              
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
      trx do |c|
        user = User.find_by(email: email)
        return user if user
        
        user = User.create(email: email)
        c.on_complete { Mailer.registration_confirmation(user.id).deliver_later }
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
      trx { |c| c.on_complete { Mailer.registration_confirmation(user.id).deliver_later } }
    end
    ```

## On complete callbacks

On-complete callbacks are defined with {TrxExt::CallbackPool#on_complete} method. An instance of {TrxExt::CallbackPool} is passed in each transaction block. You may add as much on-complete callbacks as you want by calling {TrxExt::CallbackPool#on_complete} several times - they will be executed in the order you define
them(FIFO principle). The on-complete callbacks from nested transactions will be executed from the most deep to the most top transaction. Another words, if top transaction defines `<#TrxExt::CallbackPool 0x1>` instance and nested transaction defines `<#TrxExt::CallbackPool 0x2>` instance then, when executing on-complete callbacks - the callbacks of `<#TrxExt::CallbackPool 0x2>` instance will be executed first(FILO principle).

Example:

```ruby
ActiveRecord::Base.transaction do |c1|
  User.first
  c1.on_complete { puts "This is 3rd message" }
  ActiveRecord::Base.transaction do |c2|
    User.last
    c2.on_complete { puts "This is 2nd message" }
    ActiveRecord::Base.transaction do |c3|
      c3.on_complete { puts "This is 1st message" }
      User.first(2)
    end
  end
  c1.on_complete { puts "This is 4th message" }
end
```

If you don't need to define on-complete callbacks - you may skip explicit definition of block's argument.

Example:

```ruby
ActiveRecord::Base.transaction { User.first }
```

Keep in mind, that all on-complete callbacks are not a part of the transaction. If you want to make it transactional - you need to wrap it in another transaction.

Example:

```ruby
ActiveRecord::Base.transaction do |c1|
  User.first
  c1.on_complete do
    ActiveRecord::Base.transaction do
      User.find_or_create_by(email: email)
    end
  end
end
```

You may define on-complete callbacks inside another on-complete callbacks. You may define another transactions in
on-complete callbacks. Just don't get confused in the order they are going to be executed.

Example:

```ruby
ActiveRecord::Base.transaction do |c1|
  User.first
  c1.on_complete do
    puts "This line will be executed first"
    ActiveRecord::Base.transaction do |c2|
      User.last
      c2.on_complete do
        puts "This line will be executed second"
      end
    end
    puts "This line will be executed third"
  end
end
```

Also, please avoid usage of the callbacks that belong to one transaction in another transaction explicitly. This complicates the readability of the code.

Example:

```ruby
ActiveRecord::Base.transaction do |c1|
  User.first
  c1.on_complete do
    ActiveRecord::Base.transaction do
      User.last
      c1.on_complete do
        puts "This will be executed at the time when parent transaction's on-complete callbacks are executed!"
      end
    end
  end
end
```

## On complete callbacks integrity

* Don't define callbacks blocks as lambdas unless you are 100% sure what you are doing. Lambda has a bit different behaviour comparing to Proc. Refer to [ruby documentation](https://ruby-doc.org/core-2.6.5/Proc.html#class-Proc-label-Lambda+and+non-lambda+semantics).

* When defining a callback - make sure that it does not depend on transaction's integrity. Another words - define it in a way like it is a normal code implementation outside the transaction:

  #### Bad
    ```ruby
    trx do |c|
      user = User.find(id)
      user.referrals.create(referral_attrs)
      c.on_complete do  
        Mailer.new_referral(
          user_id: user.id, total_referrals: user.referrals.count
        ).deliver_later 
      end
    end
    ```

  #### Explanation
  The example above introduces two issues:
  - `on_complete` callback does not depend on the result of `user.referrals.create(referral_attrs)`. And it should - we only need to send the email only if referral is created. Solution - add the condition for the `on_complete` callback
  - the number of user's referrals `user.referrals.count` is calculated inside `on_complete`, but it should be calculated within the transaction. Solution - calculate referrals count in transaction, extract its value into local variable and use that variable in the `on_complete` callback

  #### Good
    ```ruby
    trx do |c|
      user = User.find(id)
      referral = user.referrals.create(referral_attrs)
      if referral.persisted?
        total_referrals = user.referrals.count
        c.on_complete do 
          Mailer.new_referral(user_id: user.id, total_referrals: total_referrals).deliver_later
        end
      end
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

  - After checking out the repo, run `bin/setup` to install dependencies.
  - Setup postgresql server with `serializable` transaction isolation level - you have to set `default_transaction_isolation` config option to `serializable` in your `postgresql.conf` file
  - Create pg user and a database. This database will be used to run tests. When running console, this database will be used as a default database to connect to. Example:
    ```shell
    sudo -u postgres createuser postgres --superuser
    sudo -u postgres psql --command="CREATE DATABASE trx_ext_db OWNER postgres"    
    ```
  - Setup db connection settings. Copy config sample and edit it to match your created pg user and database:
    ```shell
    cp spec/support/config/database.yml.sample spec/support/config/database.yml  
    ```
    
Now you can run `bin/console` for an interactive prompt that will allow you to experiment.

### Tests

You can run tests for currently installed AR using `rspec` command. There is `bin/test_all_ar_versions` executable that allows you to run tests within all supported AR versions(see [TrxExt::SUPPORTED_AR_VERSIONS](lib/trx_ext/version.rb)) as well.

### Other

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/intale/trx_ext. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/intale/trx_ext/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the TrxExt project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/intale/trx_ext/blob/master/CODE_OF_CONDUCT.md).

## TODO

- integrate GitHub Actions

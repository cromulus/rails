require 'thread'

module ActiveRecord
  # See ActiveRecord::Transactions::ClassMethods for documentation.
  module Transactions
    extend ActiveSupport::Concern

    class TransactionError < ActiveRecordError # :nodoc:
    end

    included do
      [:destroy, :save, :save!].each do |method|
        alias_method_chain method, :transactions
      end

      define_model_callbacks :commit, :commit_on_update, :commit_on_create, :commit_on_destroy, :only => :after
      define_model_callbacks :rollback, :rollback_on_update, :rollback_on_create, :rollback_on_destroy
    end

    # Transactions are protective blocks where SQL statements are only permanent
    # if they can all succeed as one atomic action. The classic example is a
    # transfer between two accounts where you can only have a deposit if the
    # withdrawal succeeded and vice versa. Transactions enforce the integrity of
    # the database and guard the data against program errors or database
    # break-downs. So basically you should use transaction blocks whenever you
    # have a number of statements that must be executed together or not at all.
    # Example:
    #
    #   ActiveRecord::Base.transaction do
    #     david.withdrawal(100)
    #     mary.deposit(100)
    #   end
    #
    # This example will only take money from David and give to Mary if neither
    # +withdrawal+ nor +deposit+ raises an exception. Exceptions will force a
    # ROLLBACK that returns the database to the state before the transaction was
    # begun. Be aware, though, that the objects will _not_ have their instance
    # data returned to their pre-transactional state.
    #
    # == Different Active Record classes in a single transaction
    #
    # Though the transaction class method is called on some Active Record class,
    # the objects within the transaction block need not all be instances of
    # that class. This is because transactions are per-database connection, not
    # per-model.
    #
    # In this example a <tt>Balance</tt> record is transactionally saved even
    # though <tt>transaction</tt> is called on the <tt>Account</tt> class:
    #
    #   Account.transaction do
    #     balance.save!
    #     account.save!
    #   end
    #
    # Note that the +transaction+ method is also available as a model instance
    # method. For example, you can also do this:
    #
    #   balance.transaction do
    #     balance.save!
    #     account.save!
    #   end
    #
    # == Transactions are not distributed across database connections
    #
    # A transaction acts on a single database connection.  If you have
    # multiple class-specific databases, the transaction will not protect
    # interaction among them.  One workaround is to begin a transaction
    # on each class whose models you alter:
    #
    #   Student.transaction do
    #     Course.transaction do
    #       course.enroll(student)
    #       student.units += course.units
    #     end
    #   end
    #
    # This is a poor solution, but full distributed transactions are beyond
    # the scope of Active Record.
    #
    # == Save and destroy are automatically wrapped in a transaction
    #
    # Both Base#save and Base#destroy come wrapped in a transaction that ensures
    # that whatever you do in validations or callbacks will happen under the
    # protected cover of a transaction. So you can use validations to check for
    # values that the transaction depends on or you can raise exceptions in the
    # callbacks to rollback, including <tt>after_*</tt> callbacks.
    #
    # == Exception handling and rolling back
    #
    # Also have in mind that exceptions thrown within a transaction block will
    # be propagated (after triggering the ROLLBACK), so you should be ready to
    # catch those in your application code.
    #
    # One exception is the ActiveRecord::Rollback exception, which will trigger
    # a ROLLBACK when raised, but not be re-raised by the transaction block.
    #
    # *Warning*: one should not catch ActiveRecord::StatementInvalid exceptions
    # inside a transaction block. StatementInvalid exceptions indicate that an
    # error occurred at the database level, for example when a unique constraint
    # is violated. On some database systems, such as PostgreSQL, database errors
    # inside a transaction causes the entire transaction to become unusable
    # until it's restarted from the beginning. Here is an example which
    # demonstrates the problem:
    #
    #   # Suppose that we have a Number model with a unique column called 'i'.
    #   Number.transaction do
    #     Number.create(:i => 0)
    #     begin
    #       # This will raise a unique constraint error...
    #       Number.create(:i => 0)
    #     rescue ActiveRecord::StatementInvalid
    #       # ...which we ignore.
    #     end
    #
    #     # On PostgreSQL, the transaction is now unusable. The following
    #     # statement will cause a PostgreSQL error, even though the unique
    #     # constraint is no longer violated:
    #     Number.create(:i => 1)
    #     # => "PGError: ERROR:  current transaction is aborted, commands
    #     #     ignored until end of transaction block"
    #   end
    #
    # One should restart the entire transaction if a StatementError occurred.
    #
    # == Nested transactions
    #
    # #transaction calls can be nested. By default, this makes all database
    # statements in the nested transaction block become part of the parent
    # transaction. For example:
    #
    #   User.transaction do
    #     User.create(:username => 'Kotori')
    #     User.transaction do
    #       User.create(:username => 'Nemu')
    #       raise ActiveRecord::Rollback
    #     end
    #   end
    #
    #   User.find(:all)  # => empty
    #
    # It is also possible to requires a sub-transaction by passing
    # <tt>:requires_new => true</tt>.  If anything goes wrong, the
    # database rolls back to the beginning of the sub-transaction
    # without rolling back the parent transaction. For example:
    #
    #   User.transaction do
    #     User.create(:username => 'Kotori')
    #     User.transaction(:requires_new => true) do
    #       User.create(:username => 'Nemu')
    #       raise ActiveRecord::Rollback
    #     end
    #   end
    #
    #   User.find(:all)  # => Returns only Kotori
    #
    # Most databases don't support true nested transactions. At the time of
    # writing, the only database that we're aware of that supports true nested
    # transactions, is MS-SQL. Because of this, Active Record emulates nested
    # transactions by using savepoints. See
    # http://dev.mysql.com/doc/refman/5.0/en/savepoints.html
    # for more information about savepoints.
    #
    # === Callbacks
    #
    # There are two types of callbacks associated with committing and rolling back transactions:
    # after_commit and after_rollback.
    #
    # The after_commit callbacks are called on every record saved or destroyed within a
    # transaction immediately after the  transaction is committed. The after_rollback callbacks
    # are called on every record saved or destroyed within a transaction immediately after the
    # transaction or savepoint is rolled back.
    #
    # Additionally, there are callbacks for after_commit_on_create, after_rollback_on_create,
    # after_commit_on_update, after_rollback_on_update, after_commit_on_destroy, and
    # after_rollback_on_destroy which are only called if a record is created, updated or destroyed
    # in the transaction.
    #
    # These callbacks are useful for interacting with other systems since you will be guaranteed
    # that the callback is only executed when the database is in a permanent state. For example,
    # after_commit is a good spot to put in a hook to clearing a cache since clearing it from
    # within a transaction could trigger the cache to be regenerated before the database is updated.
    #
    # === Caveats
    #
    # If you're on MySQL, then do not use DDL operations in nested transactions
    # blocks that are emulated with savepoints. That is, do not execute statements
    # like 'CREATE TABLE' inside such blocks. This is because MySQL automatically
    # releases all savepoints upon executing a DDL operation. When #transaction
    # is finished and tries to release the savepoint it created earlier, a
    # database error will occur because the savepoint has already been
    # automatically released. The following example demonstrates the problem:
    #
    #   Model.connection.transaction do                           # BEGIN
    #     Model.connection.transaction(:requires_new => true) do  # CREATE SAVEPOINT active_record_1
    #       Model.connection.create_table(...)                    # active_record_1 now automatically released
    #     end                                                     # RELEASE savepoint active_record_1
    #                                                             # ^^^^ BOOM! database error!
    #   end
    #
    # Note that "TRUNCATE" is also a MySQL DDL statement!
    module ClassMethods
      # See ActiveRecord::Transactions::ClassMethods for detailed documentation.
      def transaction(options = {}, &block)
        # See the ConnectionAdapters::DatabaseStatements#transaction API docs.
        connection.transaction(options, &block)
      end
    end

    # See ActiveRecord::Transactions::ClassMethods for detailed documentation.
    def transaction(&block)
      self.class.transaction(&block)
    end

    def destroy_with_transactions #:nodoc:
      with_transaction_returning_status(:destroy_without_transactions)
    end

    def save_with_transactions(*args) #:nodoc:
      rollback_active_record_state! { with_transaction_returning_status(:save_without_transactions, *args) }
    end

    def save_with_transactions! #:nodoc:
      with_transaction_returning_status(:save_without_transactions!)
    end

    # Reset id and @new_record if the transaction rolls back.
    def rollback_active_record_state!
      remember_transaction_record_state
      yield
    rescue Exception
      restore_transaction_record_state
      raise
    ensure
      clear_transaction_record_state
    end

    # Call the after_commit callbacks
    def committed! #:nodoc:
      if transaction_record_state(:new_record)
        _run_commit_on_create_callbacks
      elsif transaction_record_state(:destroyed)
        _run_commit_on_destroy_callbacks
      else
        _run_commit_on_update_callbacks
      end
      _run_commit_callbacks
    ensure
      clear_transaction_record_state
    end

    # Call the after rollback callbacks. The restore_state argument indicates if the record
    # state should be rolled back to the beginning or just to the last savepoint.
    def rolledback!(force_restore_state = false) #:nodoc:
      if transaction_record_state(:new_record)
        _run_rollback_on_create_callbacks
      elsif transaction_record_state(:destroyed)
        _run_rollback_on_destroy_callbacks
      else
        _run_rollback_on_update_callbacks
      end
      _run_rollback_callbacks
    ensure
      restore_transaction_record_state(force_restore_state)
    end

    # Add the record to the current transaction so that the :after_rollback and :after_commit callbacks
    # can be called.
    def add_to_transaction
      if self.class.connection.add_transaction_record(self)
        remember_transaction_record_state
      end
    end

    # Executes +method+ within a transaction and captures its return value as a
    # status flag. If the status is true the transaction is committed, otherwise
    # a ROLLBACK is issued. In any case the status flag is returned.
    #
    # This method is available within the context of an ActiveRecord::Base
    # instance.
    def with_transaction_returning_status(method, *args)
      status = nil
      self.class.transaction do
        add_to_transaction
        status = send(method, *args)
        raise ActiveRecord::Rollback unless status
      end
      status
    end

    protected

    # Save the new record state and id of a record so it can be restored later if a transaction fails.
    def remember_transaction_record_state #:nodoc
      @_start_transaction_state ||= {}
      unless @_start_transaction_state.include?(:new_record)
        @_start_transaction_state[:id] = id if has_attribute?(self.class.primary_key)
        @_start_transaction_state[:new_record] = @new_record
      end
      unless @_start_transaction_state.include?(:destroyed)
        @_start_transaction_state[:destroyed] = @new_record
      end
      @_start_transaction_state[:level] = (@_start_transaction_state[:level] || 0) + 1
    end

    # Clear the new record state and id of a record.
    def clear_transaction_record_state #:nodoc
      if defined?(@_start_transaction_state)
        @_start_transaction_state[:level] = (@_start_transaction_state[:level] || 0) - 1
        remove_instance_variable(:@_start_transaction_state) if @_start_transaction_state[:level] < 1
      end
    end

    # Restore the new record state and id of a record that was previously saved by a call to save_record_state.
    def restore_transaction_record_state(force = false) #:nodoc
      if defined?(@_start_transaction_state)
        @_start_transaction_state[:level] = (@_start_transaction_state[:level] || 0) - 1
        if @_start_transaction_state[:level] < 1
          restore_state = remove_instance_variable(:@_start_transaction_state)
          if restore_state
            @new_record = restore_state[:new_record]
            @destroyed = restore_state[:destroyed]
            if restore_state[:id]
              self.id = restore_state[:id]
            else
              @attributes.delete(self.class.primary_key)
              @attributes_cache.delete(self.class.primary_key)
            end
          end
        end
      end
    end

    # Determine if a record was created or destroyed in a transaction. State should be one of :new_record or :destroyed.
    def transaction_record_state(state) #:nodoc
      @_start_transaction_state[state] if defined?(@_start_transaction_state)
    end
  end
end

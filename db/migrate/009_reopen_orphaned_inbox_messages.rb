# Inbox messages whose saved entry was deleted before deleting put them back
# (2026-10-21) were left as "recorded" with nothing to open: reopen them.
Sequel.migration do
  up do
    from(:inbox_messages).where(status: 'recorded')
                         .where(Sequel.|({ transaction_id: nil }, Sequel.~(transaction_id: from(:transactions).select(:id))))
                         .update(status: 'pending', transaction_id: nil, updated_at: Time.now)
  end

  down do
    # Nothing to undo: reopened messages stay waiting in the inbox.
  end
end

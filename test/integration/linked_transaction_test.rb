# frozen_string_literal: true

require 'integration_test_case'

# Seeds its own ACCPAY bill and ACCREC invoice: a source line item can carry only
# one linked transaction, so pointing at existing bills would break re-recording.
class AboutLinkedTransactions < IntegrationTestCase
  CONTACT_NAME = 'Billable Expense Test Customer'

  def setup
    @client = oauth2_client
    accounts = @client.Account.all.select { |a| a.status == 'ACTIVE' }
    @expense_account = accounts.find { |a| a.type == 'EXPENSE' }
    @revenue_account = accounts.find { |a| a.type == 'REVENUE' }
  end

  can 'create a billable expense for a customer and allocate it to a sales invoice' do
    bill = create_invoice('ACCPAY', @expense_account, 'AUTHORISED')
    source_line = bill.line_items.first
    refute_nil source_line.line_item_id

    linked = @client.LinkedTransaction.build(
      source_transaction_id: bill.invoice_id,
      source_line_item_id: source_line.line_item_id,
      contact_id: bill.contact.contact_id
    )
    assert linked.save, "Create failed: #{linked.errors.inspect}"
    refute_nil linked.id
    assert_equal 'BILLABLEEXPENSE', linked.type
    assert_equal 'ACCPAY', linked.source_transaction_type_code
    assert_equal bill.contact.contact_id, linked.contact_id
    refute_nil linked.status
    assert_nil linked.target_transaction_id

    sales_invoice = create_invoice('ACCREC', @revenue_account, 'DRAFT')
    target_line = sales_invoice.line_items.first
    linked.target_transaction_id = sales_invoice.invoice_id
    linked.target_line_item_id = target_line.line_item_id
    assert linked.save, "Update failed: #{linked.errors.inspect}"
    assert_equal sales_invoice.invoice_id, linked.target_transaction_id
    assert_equal target_line.line_item_id, linked.target_line_item_id

    found = @client.LinkedTransaction.find(linked.id)
    assert_equal target_line.line_item_id, found.target_line_item_id
    assert_equal linked.status, found.status
  end

  can 'filter by SourceTransactionID and by ContactID with Status' do
    bill = create_invoice('ACCPAY', @expense_account, 'AUTHORISED')
    linked = @client.LinkedTransaction.create(
      source_transaction_id: bill.invoice_id,
      source_line_item_id: bill.line_items.first.line_item_id,
      contact_id: bill.contact.contact_id
    )
    refute_nil linked.id, "Create failed: #{linked.errors.inspect}"

    by_source = @client.LinkedTransaction.all(SourceTransactionID: bill.invoice_id)
    assert_equal [linked.id], by_source.map(&:id)

    by_contact = @client.LinkedTransaction.all(ContactID: bill.contact.contact_id, status: linked.status)
    assert_includes by_contact.map(&:id), linked.id
    assert(by_contact.all? { |lt| lt.contact_id == bill.contact.contact_id && lt.status == linked.status })
  end

  private

  def create_invoice(type, account, status)
    invoice = @client.Invoice.build(
      type: type,
      status: status,
      contact: { name: CONTACT_NAME },
      date: Date.new(2026, 10, 12),
      due_date: Date.new(2026, 10, 26),
      line_items: [{ description: "Billable expense #{type} line", quantity: 1, unit_amount: 50,
                     account_code: account.code }]
    )
    assert invoice.save, "#{type} invoice failed: #{invoice.errors.inspect}"
    invoice
  end
end

// SQLite schema and versioned migrations.
//
// RULES
//  * Never edit a migration that has shipped. Add a new one with the next number.
//  * Migrations run inside one transaction (sqflite onCreate/onUpgrade). If any
//    statement fails the whole upgrade rolls back and the database stays on the
//    old version — the app then shows a recovery screen. The database is never
//    deleted or recreated automatically.

const int kSchemaVersion = 1;

/// Business tables, in an order that respects foreign keys when inserting.
const List<String> kBusinessTables = [
  'settings', 'counters', 'users', 'products', 'customers', 'suppliers',
  'documents', 'document_items', 'payments',
  'purchases', 'purchase_items', 'purchase_payments',
  'expenses', 'fixed_expenses', 'stockmoves', 'gallery',
];

final Map<int, List<String>> kMigrations = {
  1: [
    // ---- configuration ----
    '''CREATE TABLE settings(
      id TEXT PRIMARY KEY NOT NULL,
      data TEXT NOT NULL,
      updated_at INTEGER)''',
    '''CREATE TABLE counters(
      id TEXT PRIMARY KEY NOT NULL,
      n INTEGER NOT NULL DEFAULT 0 CHECK(n >= 0),
      extra TEXT)''',
    '''CREATE TABLE users(
      id TEXT PRIMARY KEY NOT NULL,
      username TEXT NOT NULL COLLATE NOCASE UNIQUE,
      name TEXT, pass TEXT, role TEXT, active INTEGER, perms TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    // ---- catalog ----
    '''CREATE TABLE products(
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL, category TEXT, unit TEXT,
      price REAL NOT NULL DEFAULT 0,
      stocked INTEGER, stock REAL, default_basis TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    '''CREATE TABLE customers(
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL, phone TEXT, address TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_customers_name ON customers(name)',
    '''CREATE TABLE suppliers(
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL, phone TEXT, address TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    // ---- sales: invoices & quotations (orders) ----
    // customer_id is a soft link (no FK): a bill keeps its own customer name/phone
    // snapshot, so old bills stay correct even if a customer record changes.
    '''CREATE TABLE documents(
      id TEXT PRIMARY KEY NOT NULL,
      type TEXT NOT NULL CHECK(type IN ('invoice','quote')),
      no TEXT NOT NULL,
      date TEXT NOT NULL,
      customer_id TEXT, customer_name TEXT, customer_phone TEXT, branch_id TEXT,
      discount REAL NOT NULL DEFAULT 0,
      tax_pct REAL NOT NULL DEFAULT 0,
      note TEXT, order_status TEXT, from_quote TEXT, stock_applied INTEGER,
      subtotal REAL NOT NULL DEFAULT 0,
      tax_amount REAL NOT NULL DEFAULT 0,
      grand_total REAL NOT NULL DEFAULT 0,
      created_at INTEGER, updated_at INTEGER, extra TEXT,
      UNIQUE(type, no))''',
    'CREATE INDEX idx_documents_customer ON documents(customer_id)',
    'CREATE INDEX idx_documents_date ON documents(date)',
    // agreed rate + measurements are stored per line (historical pricing snapshot)
    '''CREATE TABLE document_items(
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      line_no INTEGER NOT NULL DEFAULT 0,
      product_id TEXT, description TEXT,
      width REAL, height REAL,
      measure_unit TEXT NOT NULL DEFAULT 'ft' CHECK(measure_unit IN ('ft','in')),
      qty REAL NOT NULL DEFAULT 0,
      unit TEXT,
      rate REAL NOT NULL DEFAULT 0,
      basis TEXT,
      area_sqft REAL NOT NULL DEFAULT 0,
      line_total REAL NOT NULL DEFAULT 0,
      extra TEXT)''',
    'CREATE INDEX idx_items_document ON document_items(document_id)',
    // every payment is its own row (never one editable "paid" number)
    '''CREATE TABLE payments(
      id TEXT PRIMARY KEY NOT NULL,
      document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
      amount REAL NOT NULL CHECK(amount > 0),
      date TEXT, method TEXT, note TEXT,
      created_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_payments_document ON payments(document_id)',
    // ---- purchases ----
    '''CREATE TABLE purchases(
      id TEXT PRIMARY KEY NOT NULL,
      no TEXT NOT NULL UNIQUE,
      date TEXT NOT NULL,
      branch_id TEXT, supplier_id TEXT, supplier_name TEXT,
      discount REAL NOT NULL DEFAULT 0,
      note TEXT, stock_applied INTEGER,
      grand_total REAL NOT NULL DEFAULT 0,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_purchases_supplier ON purchases(supplier_id)',
    '''CREATE TABLE purchase_items(
      id TEXT PRIMARY KEY NOT NULL,
      purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
      line_no INTEGER NOT NULL DEFAULT 0,
      product_id TEXT, description TEXT,
      qty REAL NOT NULL DEFAULT 0,
      rate REAL NOT NULL DEFAULT 0,
      basis TEXT, unit TEXT, width REAL, height REAL,
      line_total REAL NOT NULL DEFAULT 0,
      extra TEXT)''',
    'CREATE INDEX idx_pitems_purchase ON purchase_items(purchase_id)',
    '''CREATE TABLE purchase_payments(
      id TEXT PRIMARY KEY NOT NULL,
      purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
      amount REAL NOT NULL CHECK(amount > 0),
      date TEXT, method TEXT, created_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_ppay_purchase ON purchase_payments(purchase_id)',
    // ---- expenses ----
    '''CREATE TABLE expenses(
      id TEXT PRIMARY KEY NOT NULL,
      date TEXT NOT NULL,
      amount REAL NOT NULL CHECK(amount >= 0),
      category TEXT, branch_id TEXT, description TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_expenses_date ON expenses(date)',
    '''CREATE TABLE fixed_expenses(
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT NOT NULL, category TEXT,
      amount REAL NOT NULL DEFAULT 0 CHECK(amount >= 0),
      branch_id TEXT, active INTEGER, start_month TEXT, end_month TEXT, note TEXT,
      created_at INTEGER, updated_at INTEGER, extra TEXT)''',
    // ---- stock & showcase ----
    '''CREATE TABLE stockmoves(
      id TEXT PRIMARY KEY NOT NULL,
      date TEXT, product_id TEXT,
      type TEXT CHECK(type IN ('in','out')),
      qty REAL NOT NULL DEFAULT 0, reason TEXT, ref TEXT,
      created_at INTEGER, extra TEXT)''',
    'CREATE INDEX idx_stockmoves_product ON stockmoves(product_id)',
    '''CREATE TABLE gallery(
      id TEXT PRIMARY KEY NOT NULL,
      title TEXT, category TEXT, img TEXT, seeded INTEGER,
      created_at INTEGER, extra TEXT)''',
    // ---- integrity & sync metadata ----
    '''CREATE TABLE audit_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL, entity TEXT NOT NULL, record_id TEXT,
      action TEXT NOT NULL, summary TEXT)''',
    // one pending operation per record (later changes replace earlier ones)
    '''CREATE TABLE sync_queue(
      entity TEXT NOT NULL, record_id TEXT NOT NULL,
      op_id TEXT NOT NULL,
      op TEXT NOT NULL CHECK(op IN ('upsert','delete')),
      local_modified INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','failed','conflict')),
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, force INTEGER NOT NULL DEFAULT 0, remote_hash TEXT,
      created_at INTEGER NOT NULL,
      PRIMARY KEY(entity, record_id))''',
    'CREATE INDEX idx_sync_queue_status ON sync_queue(status, next_attempt_at)',
    // what the app last wrote to the spreadsheet for each record (for conflict detection)
    '''CREATE TABLE record_sync(
      entity TEXT NOT NULL, record_id TEXT NOT NULL,
      last_pushed_hash TEXT, last_synced_at TEXT,
      PRIMARY KEY(entity, record_id))''',
    '''CREATE TABLE sync_log(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL, event TEXT NOT NULL, entity TEXT, record_id TEXT,
      result TEXT, message TEXT)''',
    '''CREATE TABLE kv(
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT)''',
  ],
};

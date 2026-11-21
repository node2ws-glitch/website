#!/usr/bin/env bash
# ============================================================
# AG TECH HOSTING — COMPLETE AUTO-INSTALLER (setup.sh) v2
# Generates full project, installs deps, initializes DB.
# Safe to re-run. Ubuntu/Debian compatible.
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; }
step() { echo -e "\n${CYAN}▶ $1${NC}"; }
die()  { err "$1"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# ============================================================
# 0. NORMALIZE + SELF-CHECK
# ============================================================
sed -i 's/\r$//' "$0" 2>/dev/null || true

# ============================================================
# 1. SYSTEM CHECKS
# ============================================================
step "Checking system requirements"
command -v node >/dev/null 2>&1 || die "Node.js not found. Install Node 18+ from https://nodejs.org"
command -v npm  >/dev/null 2>&1 || die "npm not found."
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
[ "$NODE_MAJOR" -lt 18 ] && die "Node.js 18+ required (found $(node -v))"
log "Node $(node -v) — OK"
log "npm $(npm -v) — OK"

if command -v apt-get >/dev/null 2>&1; then
  if ! dpkg -s build-essential >/dev/null 2>&1; then
    warn "build-essential missing (needed for better-sqlite3 fallback build)."
    warn "If npm install fails, run: sudo apt-get install -y build-essential python3"
  else
    log "build-essential present"
  fi
fi

# ============================================================
# 2. DIRECTORY STRUCTURE
# ============================================================
step "Creating directory structure"
mkdir -p public/css public/js public/images public/uploads
mkdir -p views/partials views/customer views/admin
chmod 755 public/uploads
log "Directories created under $PROJECT_DIR"

# ============================================================
# 3. package.json
# ============================================================
step "Writing package.json"
cat > package.json <<'AGH_PKG_EOF'
{
  "name": "ag-tech-hosting",
  "version": "1.0.0",
  "description": "AG Tech Hosting - Premium Hosting Provider Platform",
  "main": "app.js",
  "scripts": {
    "start": "node app.js",
    "dev": "NODE_ENV=development node app.js"
  },
  "keywords": ["hosting", "game-hosting", "vps", "minecraft", "express", "ejs"],
  "author": "AG Tech Hosting",
  "license": "MIT",
  "dependencies": {
    "better-sqlite3": "^11.3.0",
    "bcryptjs": "^2.4.3",
    "connect-flash": "^0.1.1",
    "connect-sqlite3": "^0.9.13",
    "cookie-parser": "^1.4.7",
    "csurf": "^1.11.0",
    "dotenv": "^16.4.5",
    "ejs": "^3.1.10",
    "express": "^4.21.0",
    "express-rate-limit": "^7.4.0",
    "express-session": "^1.18.0",
    "express-validator": "^7.2.0",
    "helmet": "^7.1.0",
    "method-override": "^3.0.0",
    "morgan": "^1.10.0",
    "multer": "^1.4.5-lts.1",
    "nodemailer": "^6.9.15",
    "razorpay": "^2.9.4",
    "stripe": "^16.12.0"
  },
  "engines": { "node": ">=18.0.0" }
}
AGH_PKG_EOF
log "package.json written"

# ============================================================
# 4. .env / .env.example
# ============================================================
step "Writing .env.example"
cat > .env.example <<'AGH_ENVEX_EOF'
# AG TECH HOSTING - ENVIRONMENT CONFIGURATION

PORT=3000
NODE_ENV=production
BASE_URL=http://localhost:3000

SESSION_SECRET=change-this-to-a-long-random-string-min-64-chars
ENCRYPTION_KEY=change-this-to-a-32-char-encryption-key
COOKIE_SECURE=false

DATABASE_PATH=./database.sqlite

ADMIN_EMAIL=admin@agtechhosting.com
ADMIN_PASSWORD=ChangeMeNow!123
ADMIN_NAME=Administrator

SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_FROM=AG Tech Hosting <no-reply@agtechhosting.com>

PAYMENT_PROVIDER=manual_upi
CURRENCY=INR

RAZORPAY_KEY_ID=
RAZORPAY_KEY_SECRET=
RAZORPAY_WEBHOOK_SECRET=

STRIPE_SECRET_KEY=
STRIPE_PUBLISHABLE_KEY=
STRIPE_WEBHOOK_SECRET=

PAYPAL_CLIENT_ID=
PAYPAL_CLIENT_SECRET=
PAYPAL_MODE=sandbox

CASHFREE_APP_ID=
CASHFREE_SECRET_KEY=
CASHFREE_ENV=sandbox

PHONEPE_CLIENT_ID=
PHONEPE_CLIENT_SECRET=
PHONEPE_ENV=sandbox

UPI_ID=
UPI_NAME=AG Tech Hosting

BANK_NAME=
BANK_ACCOUNT_NAME=
BANK_ACCOUNT_NUMBER=
BANK_IFSC=
BANK_BRANCH=

DISCORD_INVITE_URL=
AGH_ENVEX_EOF
log ".env.example written"

if [ -f .env ]; then
  warn ".env exists — preserving (backup: .env.bak)"
  cp .env .env.bak
else
  cp .env.example .env
  if command -v openssl >/dev/null 2>&1; then
    SEC=$(openssl rand -hex 48)
    ENC=$(openssl rand -hex 16)
  else
    SEC=$(node -e "console.log(require('crypto').randomBytes(48).toString('hex'))")
    ENC=$(node -e "console.log(require('crypto').randomBytes(16).toString('hex'))")
  fi
  node -e "
    const fs=require('fs');
    let s=fs.readFileSync('.env','utf8');
    s=s.replace(/^SESSION_SECRET=.*/m,'SESSION_SECRET=$SEC');
    s=s.replace(/^ENCRYPTION_KEY=.*/m,'ENCRYPTION_KEY=$ENC');
    fs.writeFileSync('.env',s);
  "
  log ".env created with secure random SESSION_SECRET + ENCRYPTION_KEY"
fi

# ============================================================
# 5. app.js
# ============================================================
step "Writing app.js (large file — please wait)"
cat > app.js <<'AGH_APP_EOF'
/* =====================================================================
   AG TECH HOSTING — COMPLETE BACKEND (app.js)
   ===================================================================== */
'use strict';
require('dotenv').config();

const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const session = require('express-session');
const SQLiteStore = require('connect-sqlite3')(session);
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const csurf = require('csurf');
const cookieParser = require('cookie-parser');
const flash = require('connect-flash');
const methodOverride = require('method-override');
const morgan = require('morgan');
const multer = require('multer');
const Database = require('better-sqlite3');
const nodemailer = require('nodemailer');
const { body, validationResult } = require('express-validator');

const PORT = parseInt(process.env.PORT || '3000', 10);
const NODE_ENV = process.env.NODE_ENV || 'development';
const BASE_URL = process.env.BASE_URL || `http://localhost:${PORT}`;
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomBytes(48).toString('hex');
const ENCRYPTION_KEY = (process.env.ENCRYPTION_KEY || crypto.randomBytes(16).toString('hex')).padEnd(32,'0').slice(0,32);
const DATABASE_PATH = process.env.DATABASE_PATH || path.join(__dirname, 'database.sqlite');
const CURRENCY = process.env.CURRENCY || 'INR';
const ADMIN_EMAIL = (process.env.ADMIN_EMAIL || 'admin@agtechhosting.com').toLowerCase();
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'ChangeMeNow!123';
const ADMIN_NAME = process.env.ADMIN_NAME || 'Administrator';

const UPLOAD_DIR = path.join(__dirname, 'public', 'uploads');
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const IV_LEN = 16;
function encrypt(t){ if(!t) return ''; const iv=crypto.randomBytes(IV_LEN); const c=crypto.createCipheriv('aes-256-cbc',Buffer.from(ENCRYPTION_KEY,'utf8'),iv); let e=c.update(String(t),'utf8','hex'); e+=c.final('hex'); return iv.toString('hex')+':'+e; }
function decrypt(t){ if(!t) return ''; try{ const p=String(t).split(':'); const iv=Buffer.from(p.shift(),'hex'); const d=crypto.createDecipheriv('aes-256-cbc',Buffer.from(ENCRYPTION_KEY,'utf8'),iv); let r=d.update(p.join(':'),'hex','utf8'); r+=d.final('utf8'); return r; }catch{ return ''; } }

const db = new Database(DATABASE_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

function initDatabase() {
  db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'customer', status TEXT NOT NULL DEFAULT 'active',
    phone TEXT, address TEXT, city TEXT, country TEXT, avatar TEXT,
    email_verified INTEGER DEFAULT 0, verify_token TEXT, reset_token TEXT, reset_expires INTEGER,
    theme TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
  CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, slug TEXT NOT NULL UNIQUE,
    description TEXT, icon TEXT, image TEXT, visible INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT, category_id INTEGER NOT NULL,
    name TEXT NOT NULL, slug TEXT NOT NULL UNIQUE, description TEXT, image TEXT, icon TEXT,
    price_monthly REAL NOT NULL DEFAULT 0, price_quarterly REAL, price_yearly REAL,
    cpu TEXT, ram TEXT, storage TEXT, bandwidth TEXT, network TEXT, location TEXT, os TEXT, features TEXT,
    stock INTEGER DEFAULT -1, featured INTEGER DEFAULT 0, popular INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'published', created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
  );
  CREATE INDEX IF NOT EXISTS idx_products_cat ON products(category_id);
  CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT, order_number TEXT NOT NULL UNIQUE, user_id INTEGER NOT NULL,
    subtotal REAL NOT NULL DEFAULT 0, discount REAL NOT NULL DEFAULT 0, tax REAL NOT NULL DEFAULT 0,
    total REAL NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT 'INR', coupon_code TEXT,
    billing_cycle TEXT NOT NULL DEFAULT 'monthly', status TEXT NOT NULL DEFAULT 'pending',
    payment_status TEXT NOT NULL DEFAULT 'unpaid', payment_gateway TEXT, payment_ref TEXT, notes TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS order_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL, product_id INTEGER NOT NULL,
    product_name TEXT NOT NULL, price REAL NOT NULL, quantity INTEGER NOT NULL DEFAULT 1,
    billing_cycle TEXT NOT NULL, specs TEXT,
    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER NOT NULL, gateway TEXT NOT NULL,
    transaction_id TEXT, amount REAL NOT NULL, currency TEXT NOT NULL DEFAULT 'INR',
    status TEXT NOT NULL DEFAULT 'pending', raw_response TEXT, verified INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS payment_gateways (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, enabled INTEGER DEFAULT 0,
    mode TEXT DEFAULT 'test', config TEXT, updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS coupons (
    id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE, type TEXT NOT NULL DEFAULT 'percent',
    value REAL NOT NULL DEFAULT 0, min_total REAL DEFAULT 0, max_uses INTEGER DEFAULT 0, uses INTEGER DEFAULT 0,
    active INTEGER DEFAULT 1, expires_at INTEGER, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS invoices (
    id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_number TEXT NOT NULL UNIQUE, order_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL, amount REAL NOT NULL, currency TEXT NOT NULL DEFAULT 'INR',
    status TEXT NOT NULL DEFAULT 'unpaid', issued_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), paid_at INTEGER,
    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS support_tickets (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_number TEXT NOT NULL UNIQUE, user_id INTEGER NOT NULL,
    subject TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'general', priority TEXT NOT NULL DEFAULT 'normal',
    status TEXT NOT NULL DEFAULT 'open', created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS ticket_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id INTEGER NOT NULL, user_id INTEGER NOT NULL,
    is_admin INTEGER DEFAULT 0, message TEXT NOT NULL, attachment TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (ticket_id) REFERENCES support_tickets(id) ON DELETE CASCADE
  );
  CREATE TABLE IF NOT EXISTS notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, title TEXT NOT NULL, message TEXT, link TEXT,
    read INTEGER DEFAULT 0, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS announcements (
    id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, message TEXT NOT NULL, type TEXT DEFAULT 'info',
    active INTEGER DEFAULT 1, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS themes (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, slug TEXT NOT NULL UNIQUE,
    variables TEXT, enabled INTEGER DEFAULT 1, is_default INTEGER DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS website_settings (key TEXT PRIMARY KEY, value TEXT);
  CREATE TABLE IF NOT EXISTS activity_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, action TEXT NOT NULL, details TEXT, ip TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS contact_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT NOT NULL, subject TEXT,
    message TEXT NOT NULL, read INTEGER DEFAULT 0, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
  );
  CREATE TABLE IF NOT EXISTS services (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, order_id INTEGER,
    product_name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active', billing_cycle TEXT, renews_at INTEGER,
    specs TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );
  `);

  if (db.prepare('SELECT COUNT(*) c FROM website_settings').get().c === 0) {
    const ins = db.prepare('INSERT INTO website_settings (key,value) VALUES (?,?)');
    const d = { site_name:'AG Tech Hosting', site_tagline:'Premium Game & VPS Hosting',
      site_description:'Next-generation hosting with instant deployment, DDoS protection and 99.9% uptime.',
      discord_invite: process.env.DISCORD_INVITE_URL||'', contact_email:'support@agtechhosting.com',
      contact_phone:'+1 000 000 0000', maintenance_mode:'0', animations_enabled:'1',
      animation_intensity:'medium', active_theme:'midnight-black', tax_rate:'0', currency: CURRENCY,
      seo_title:'AG Tech Hosting — Premium Game & VPS Hosting',
      seo_description:'Blazing fast Minecraft, VPS, RDP and bot hosting.',
      seo_keywords:'hosting,minecraft,vps,rdp' };
    db.transaction((o)=>{ for(const k in o) ins.run(k,o[k]); })(d);
  }

  if (db.prepare('SELECT COUNT(*) c FROM themes').get().c === 0) {
    const ins = db.prepare('INSERT INTO themes (name,slug,variables,enabled,is_default) VALUES (?,?,?,?,?)');
    const T = (o)=>JSON.stringify(o);
    const themes = [
      ['Midnight Black','midnight-black',T({ '--bg':'#0a0a0f','--bg-2':'#0f0f18','--card':'#12121c','--primary':'#8b5cf6','--primary-2':'#a855f7','--text':'#e8e8f0','--muted':'#8b8ba0','--border':'#1f1f2e','--gradient':'linear-gradient(135deg,#8b5cf6,#a855f7)' }),1,1],
      ['Purple Neon','purple-neon',T({ '--bg':'#0a0015','--bg-2':'#120022','--card':'#180030','--primary':'#c026d3','--primary-2':'#e879f9','--text':'#f0e8ff','--muted':'#9d8bb8','--border':'#2a1a45','--gradient':'linear-gradient(135deg,#c026d3,#e879f9)' }),1,0],
      ['Cyberpunk','cyberpunk',T({ '--bg':'#0a0a0a','--bg-2':'#111111','--card':'#161616','--primary':'#fcee0a','--primary-2':'#00f0ff','--text':'#f0f0f0','--muted':'#888888','--border':'#2a2a2a','--gradient':'linear-gradient(135deg,#fcee0a,#00f0ff)' }),1,0],
      ['Dark Blue','dark-blue',T({ '--bg':'#050a1a','--bg-2':'#0a1228','--card':'#0f1a33','--primary':'#3b82f6','--primary-2':'#60a5fa','--text':'#e0e8f5','--muted':'#7a8ba8','--border':'#1a2a45','--gradient':'linear-gradient(135deg,#3b82f6,#60a5fa)' }),1,0],
      ['Emerald Green','emerald-green',T({ '--bg':'#021008','--bg-2':'#041a10','--card':'#061f14','--primary':'#10b981','--primary-2':'#34d399','--text':'#e0f5ea','--muted':'#7aa892','--border':'#0d2e1e','--gradient':'linear-gradient(135deg,#10b981,#34d399)' }),1,0],
      ['Crimson Red','crimson-red',T({ '--bg':'#100202','--bg-2':'#1a0404','--card':'#1f0606','--primary':'#ef4444','--primary-2':'#f87171','--text':'#f5e0e0','--muted':'#a87a7a','--border':'#2e0d0d','--gradient':'linear-gradient(135deg,#ef4444,#f87171)' }),1,0],
      ['Premium Minimal Dark','minimal-dark',T({ '--bg':'#0d0d0d','--bg-2':'#131313','--card':'#1a1a1a','--primary':'#e5e5e5','--primary-2':'#ffffff','--text':'#f0f0f0','--muted':'#888888','--border':'#262626','--gradient':'linear-gradient(135deg,#e5e5e5,#ffffff)' }),1,0],
      ['Custom Theme','custom',T({ '--bg':'#0a0a0f','--bg-2':'#0f0f18','--card':'#12121c','--primary':'#8b5cf6','--primary-2':'#a855f7','--text':'#e8e8f0','--muted':'#8b8ba0','--border':'#1f1f2e','--gradient':'linear-gradient(135deg,#8b5cf6,#a855f7)' }),1,0]
    ];
    db.transaction((rows)=>{ for(const r of rows) ins.run(...r); })(themes);
  }

  if (db.prepare('SELECT COUNT(*) c FROM payment_gateways').get().c === 0) {
    const ins = db.prepare('INSERT INTO payment_gateways (name,enabled,mode,config) VALUES (?,?,?,?)');
    const g = [
      ['razorpay',0,'test',encrypt(JSON.stringify({key_id:process.env.RAZORPAY_KEY_ID||'',key_secret:process.env.RAZORPAY_KEY_SECRET||'',webhook_secret:process.env.RAZORPAY_WEBHOOK_SECRET||''}))],
      ['stripe',0,'test',encrypt(JSON.stringify({secret_key:process.env.STRIPE_SECRET_KEY||'',publishable_key:process.env.STRIPE_PUBLISHABLE_KEY||'',webhook_secret:process.env.STRIPE_WEBHOOK_SECRET||''}))],
      ['paypal',0,'sandbox',encrypt(JSON.stringify({client_id:process.env.PAYPAL_CLIENT_ID||'',client_secret:process.env.PAYPAL_CLIENT_SECRET||''}))],
      ['cashfree',0,'test',encrypt(JSON.stringify({app_id:process.env.CASHFREE_APP_ID||'',secret_key:process.env.CASHFREE_SECRET_KEY||''}))],
      ['phonepe',0,'test',encrypt(JSON.stringify({client_id:process.env.PHONEPE_CLIENT_ID||'',client_secret:process.env.PHONEPE_CLIENT_SECRET||''}))],
      ['manual_upi',1,'live',encrypt(JSON.stringify({upi_id:process.env.UPI_ID||'hosting@upi',upi_name:process.env.UPI_NAME||'AG Tech Hosting'}))],
      ['manual_bank',1,'live',encrypt(JSON.stringify({bank_name:process.env.BANK_NAME||'',account_name:process.env.BANK_ACCOUNT_NAME||'',account_number:process.env.BANK_ACCOUNT_NUMBER||'',ifsc:process.env.BANK_IFSC||'',branch:process.env.BANK_BRANCH||''}))]
    ];
    db.transaction((rows)=>{ for(const r of rows) ins.run(...r); })(g);
  }

  if (db.prepare('SELECT COUNT(*) c FROM categories').get().c === 0) {
    const insCat = db.prepare('INSERT INTO categories (name,slug,description,icon,visible,sort_order) VALUES (?,?,?,?,1,?)');
    const cats = [
      ['Game Hosting','game-hosting','High performance game server hosting','fa-gamepad',1],
      ['Minecraft Java Hosting','minecraft-java','Java edition Minecraft servers','fa-cube',2],
      ['Minecraft Bedrock Hosting','minecraft-bedrock','Bedrock edition cross-play servers','fa-cubes',3],
      ['VPS Hosting','vps-hosting','Virtual private servers with full root','fa-server',4],
      ['VDS Hosting','vds-hosting','Virtual dedicated servers','fa-hdd',5],
      ['Windows RDP','windows-rdp','Windows remote desktop','fa-windows',6],
      ['Linux RDP','linux-rdp','Linux remote desktop','fa-linux',7],
      ['Discord Bot Hosting','discord-bot-hosting','Host your Discord bots 24/7','fa-discord',8],
      ['Telegram Bot Hosting','telegram-bot-hosting','Host your Telegram bots 24/7','fa-telegram',9],
      ['Website Hosting','website-hosting','Fast website hosting with SSL','fa-globe',10],
      ['Web Application Hosting','web-app-hosting','Scalable web apps hosting','fa-code',11],
      ['Dedicated Server Hosting','dedicated-server','Bare metal dedicated servers','fa-microchip',12],
      ['Other Custom Hosting','custom-hosting','Custom hosting solutions','fa-cog',13]
    ];
    db.transaction((rows)=>{ for(const r of rows) insCat.run(...r); })(cats);
    const getCat = db.prepare('SELECT id FROM categories WHERE slug=?');
    const insP = db.prepare(`INSERT INTO products (category_id,name,slug,description,price_monthly,price_quarterly,price_yearly,cpu,ram,storage,bandwidth,network,location,os,features,featured,popular,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'published')`);
    const seeds = [
      ['minecraft-java','Minecraft Java Starter','mc-java-starter','Perfect starter plan for small survival servers.',4.99,13.99,49.99,'2 vCPU','4 GB','20 GB NVMe','Unmetered','1 Gbps','India','Java 17','["DDoS Protection","Instant Setup","Panel Access"]',1,1],
      ['minecraft-java','Minecraft Java Pro','mc-java-pro','Serious plan for modded servers and 50+ players.',9.99,27.99,99.99,'4 vCPU','8 GB','50 GB NVMe','Unmetered','1 Gbps','India','Java 17','["DDoS Protection","Instant Setup","Priority Support"]',1,1],
      ['minecraft-bedrock','Bedrock Starter','mc-bedrock-starter','Bedrock edition server for friends.',4.99,13.99,49.99,'2 vCPU','4 GB','20 GB NVMe','Unmetered','1 Gbps','India','Bedrock','["Cross-Play","Instant Setup"]',0,1],
      ['vps-hosting','VPS Starter','vps-starter','Reliable KVM VPS with full root access.',5.99,16.99,59.99,'2 vCPU','2 GB','40 GB SSD','2 TB','1 Gbps','India','Ubuntu 22.04','["Full Root","DDoS Protection"]',0,1],
      ['vps-hosting','VPS Pro','vps-pro','High performance KVM VPS.',11.99,33.99,119.99,'4 vCPU','8 GB','100 GB NVMe','4 TB','1 Gbps','India','Ubuntu 22.04','["Full Root","Daily Backups"]',1,1],
      ['windows-rdp','Windows RDP Basic','rdp-basic','Windows Server RDP with admin access.',9.99,27.99,99.99,'2 vCPU','4 GB','60 GB SSD','2 TB','1 Gbps','India','Windows Server 2022','["Admin Access"]',0,1],
      ['discord-bot-hosting','Discord Bot Starter','discord-bot-starter','Host your Discord bot 24/7.',2.99,8.49,29.99,'1 vCPU','1 GB','5 GB SSD','Unmetered','1 Gbps','India','Node.js 20','["24/7 Uptime"]',0,1],
      ['website-hosting','Website Hosting Basic','web-basic','Fast cPanel website hosting.',2.49,6.99,24.99,'1 vCPU','1 GB','10 GB SSD','Unmetered','1 Gbps','India','Linux','["cPanel","Free SSL"]',0,1]
    ];
    db.transaction((rows)=>{ for(const r of rows){ const c=getCat.get(r[0]); if(c) insP.run(c.id,r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8],r[9],r[10],r[11],r[12],r[13],r[14],r[15],r[16]); } })(seeds);
  }

  if (!db.prepare("SELECT id FROM users WHERE role='admin' LIMIT 1").get()) {
    const h = bcrypt.hashSync(ADMIN_PASSWORD, 12);
    db.prepare("INSERT INTO users (name,email,password_hash,role,email_verified) VALUES (?,?,?,'admin',1)").run(ADMIN_NAME, ADMIN_EMAIL, h);
    console.log('[init] Created initial admin:', ADMIN_EMAIL);
  }
}
initDatabase();

function setting(k, fb='') { const r=db.prepare('SELECT value FROM website_settings WHERE key=?').get(k); return r?r.value:fb; }
function setSetting(k,v){ db.prepare('INSERT INTO website_settings (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(k,String(v)); }
function getActiveTheme(){
  const slug = setting('active_theme','midnight-black');
  let t = db.prepare('SELECT * FROM themes WHERE slug=? AND enabled=1').get(slug);
  if(!t) t = db.prepare('SELECT * FROM themes WHERE is_default=1 AND enabled=1').get();
  if(!t) t = db.prepare('SELECT * FROM themes WHERE enabled=1 LIMIT 1').get();
  if(!t) t = { name:'Default', slug:'default', variables:'{}', vars:{} };
  try { t.vars = JSON.parse(t.variables||'{}'); } catch { t.vars={}; }
  return t;
}
function logActivity(uid,action,details,req){ try{ db.prepare('INSERT INTO activity_logs (user_id,action,details,ip) VALUES (?,?,?,?)').run(uid||null,action,details||'',req?(req.ip||''):''); }catch{} }
function orderNumber(){ return 'AGT-'+Date.now().toString(36).toUpperCase()+'-'+crypto.randomBytes(3).toString('hex').toUpperCase(); }
function invoiceNumber(){ return 'INV-'+new Date().getFullYear()+'-'+crypto.randomBytes(4).toString('hex').toUpperCase(); }
function ticketNumber(){ return 'TKT-'+crypto.randomBytes(4).toString('hex').toUpperCase(); }
function cycleMultiplier(c){ return c==='quarterly'?3:c==='yearly'?12:1; }
function cyclePrice(p,c){ if(c==='quarterly'&&p.price_quarterly) return p.price_quarterly; if(c==='yearly'&&p.price_yearly) return p.price_yearly; return p.price_monthly*cycleMultiplier(c); }

const app = express();
app.set('trust proxy',1);
app.set('view engine','ejs');
app.set('views', path.join(__dirname,'views'));

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      "default-src":["'self'"],
      "script-src":["'self'","'unsafe-inline'","https://cdn.jsdelivr.net","https://checkout.razorpay.com","https://js.stripe.com"],
      "style-src":["'self'","'unsafe-inline'","https://cdnjs.cloudflare.com","https://fonts.googleapis.com"],
      "font-src":["'self'","https://fonts.gstatic.com","https://cdnjs.cloudflare.com","data:"],
      "img-src":["'self'","data:","https:"],
      "connect-src":["'self'","https://api.razorpay.com","https://api.stripe.com"],
      "frame-src":["'self'","https://checkout.razorpay.com","https://js.stripe.com"],
      "script-src-attr":["'unsafe-inline'"]
    }
  },
  crossOriginEmbedderPolicy:false
}));

app.use(morgan(NODE_ENV==='production'?'combined':'dev'));
app.use(express.json({limit:'1mb'}));
app.use(express.urlencoded({extended:true,limit:'1mb'}));
app.use(cookieParser());
app.use(methodOverride('_method'));
app.use(express.static(path.join(__dirname,'public'),{maxAge:NODE_ENV==='production'?'7d':0}));

app.use(session({
  store: new SQLiteStore({db:'sessions.sqlite',dir:__dirname}),
  secret: SESSION_SECRET, resave:false, saveUninitialized:false,
  cookie:{httpOnly:true,secure:process.env.COOKIE_SECURE==='true',sameSite:'lax',maxAge:1000*60*60*24*7},
  name:'agtech.sid'
}));

app.use(csurf());
app.use(flash());

const authLimiter = rateLimit({windowMs:15*60*1000,max:30,standardHeaders:true,legacyHeaders:false});
const generalLimiter = rateLimit({windowMs:60*1000,max:300});
app.use('/auth', authLimiter);
app.use(generalLimiter);

const storage = multer.diskStorage({
  destination:(req,file,cb)=>cb(null,UPLOAD_DIR),
  filename:(req,file,cb)=>{ const s=file.originalname.replace(/[^a-zA-Z0-9._-]/g,'_').slice(-80); cb(null, Date.now()+'-'+crypto.randomBytes(4).toString('hex')+'-'+s); }
});
const upload = multer({
  storage, limits:{fileSize:5*1024*1024},
  fileFilter:(req,file,cb)=>{ const ok=/^image\/(jpeg|png|webp|gif)$/.test(file.mimetype); cb(ok?null:new Error('Only image files'),ok); }
});

let transporter = null;
if (process.env.SMTP_HOST && process.env.SMTP_USER) {
  transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST, port: parseInt(process.env.SMTP_PORT||'587'),
    secure: parseInt(process.env.SMTP_PORT||'587')===465,
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS }
  });
}
function sendMail(to,subject,html){ if(!transporter){ console.log('[mail:skipped]',to,subject); return Promise.resolve(); } return transporter.sendMail({from:process.env.SMTP_FROM||'no-reply@agtechhosting.com',to,subject,html}); }

// ===== GLOBAL LOCALS (runs for every request — customer AND admin) =====
app.use((req,res,next)=>{
  res.locals.csrfToken = req.csrfToken();
  res.locals.currentUser = null;
  res.locals.adminUser = null;
  res.locals.cartCount = 0;
  res.locals.settings = {
    site_name: setting('site_name','AG Tech Hosting'),
    site_tagline: setting('site_tagline',''),
    site_description: setting('site_description',''),
    discord_invite: setting('discord_invite',''),
    contact_email: setting('contact_email',''),
    contact_phone: setting('contact_phone',''),
    currency: setting('currency',CURRENCY),
    animations_enabled: setting('animations_enabled','1')==='1',
    animation_intensity: setting('animation_intensity','medium'),
    seo_title: setting('seo_title','AG Tech Hosting'),
    seo_description: setting('seo_description',''),
    seo_keywords: setting('seo_keywords',''),
    maintenance: setting('maintenance_mode','0')==='1'
  };
  res.locals.theme = getActiveTheme();
  res.locals.currentPath = req.path;
  res.locals.flashSuccess = req.flash('success');
  res.locals.flashError = req.flash('error');
  res.locals.flashInfo = req.flash('info');

  if (req.session.userId) {
    const u = db.prepare('SELECT * FROM users WHERE id=?').get(req.session.userId);
    if (u) {
      delete u.password_hash;
      res.locals.currentUser = u;
      if (u.role === 'admin' || u.role === 'staff') res.locals.adminUser = u;
    } else {
      req.session.userId = null;
    }
  }
  const cart = req.session.cart || [];
  res.locals.cartCount = cart.reduce((s,i)=>s+(i.quantity||1),0);
  res.locals.cart = cart;
  next();
});

app.use((req,res,next)=>{
  if (res.locals.settings.maintenance && !req.path.startsWith('/admin') && !req.path.startsWith('/auth') && req.path!=='/maintenance') {
    if (!res.locals.currentUser || res.locals.currentUser.role!=='admin') {
      return res.status(503).render('customer/maintenance-mode',{title:'Maintenance'});
    }
  }
  next();
});

function requireAuth(req,res,next){ if(!req.session.userId){ req.flash('error','Please log in.'); return res.redirect('/auth/login?next='+encodeURIComponent(req.originalUrl)); } next(); }
function requireAdmin(req,res,next){
  if(!req.session.userId){ req.flash('error','Please log in as admin.'); return res.redirect('/admin/login'); }
  const u = db.prepare('SELECT * FROM users WHERE id=?').get(req.session.userId);
  if(!u || (u.role!=='admin' && u.role!=='staff')){ req.flash('error','Access denied.'); return res.redirect('/admin/login'); }
  req.adminUser = u;
  res.locals.adminUser = u;  // ← ensures admin views always have this variable
  next();
}

const PaymentAdapters = {
  razorpay: {
    async create(req,order){
      const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get('razorpay');
      const cfg = JSON.parse(decrypt(r.config)||'{}');
      if(!cfg.key_id || !cfg.key_secret) throw new Error('Razorpay not configured');
      const RZP = require('razorpay');
      const rzp = new RZP({key_id:cfg.key_id,key_secret:cfg.key_secret});
      const o = await rzp.orders.create({amount:Math.round(order.total*100),currency:order.currency,receipt:order.order_number,notes:{order_id:String(order.id)}});
      return {mode:'client',gateway:'razorpay',key_id:cfg.key_id,rzp_order_id:o.id,amount:o.amount,currency:o.currency};
    },
    async verify(){ return false; }
  },
  stripe: {
    async create(req,order){
      const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get('stripe');
      const cfg = JSON.parse(decrypt(r.config)||'{}');
      if(!cfg.secret_key) throw new Error('Stripe not configured');
      const stripe = require('stripe')(cfg.secret_key);
      const s = await stripe.checkout.sessions.create({
        payment_method_types:['card'],
        line_items:[{price_data:{currency:order.currency.toLowerCase(),product_data:{name:'Order '+order.order_number},unit_amount:Math.round(order.total*100)},quantity:1}],
        mode:'payment',
        success_url: BASE_URL+'/checkout/success?session_id={CHECKOUT_SESSION_ID}&order='+order.order_number,
        cancel_url: BASE_URL+'/checkout/cancel?order='+order.order_number,
        client_reference_id: order.order_number, metadata:{order_id:String(order.id)}
      });
      return {mode:'redirect',gateway:'stripe',url:s.url,session_id:s.id};
    },
    async verify(){ return false; }
  },
  paypal: {
    async create(req,order){
      const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get('paypal');
      const cfg = JSON.parse(decrypt(r.config)||'{}');
      const env = r.mode==='live'?'https://api-m.paypal.com':'https://api-m.sandbox.paypal.com';
      const auth = Buffer.from(cfg.client_id+':'+cfg.client_secret).toString('base64');
      const tr = await fetch(env+'/v1/oauth2/token',{method:'POST',headers:{Authorization:'Basic '+auth,'Content-Type':'application/x-www-form-urlencoded'},body:'grant_type=client_credentials'});
      const {access_token} = await tr.json();
      const or = await fetch(env+'/v2/checkout/orders',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+access_token},body:JSON.stringify({intent:'CAPTURE',purchase_units:[{reference_id:order.order_number,amount:{currency_code:order.currency,value:order.total.toFixed(2)}}],application_context:{return_url:BASE_URL+'/checkout/success?order='+order.order_number,cancel_url:BASE_URL+'/checkout/cancel?order='+order.order_number}})});
      const po = await or.json();
      const appr = (po.links||[]).find(l=>l.rel==='approve');
      return {mode:'redirect',gateway:'paypal',url:appr?appr.href:'/'};
    },
    async verify(){ return false; }
  },
  cashfree: { async create(){ return {mode:'manual',gateway:'cashfree',message:'Cashfree requires account setup.'}; }, async verify(){ return false; } },
  phonepe:  { async create(){ return {mode:'manual',gateway:'phonepe',message:'PhonePe requires account setup.'}; }, async verify(){ return false; } },
  manual_upi: {
    async create(req,order){
      const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get('manual_upi');
      const cfg = JSON.parse(decrypt(r.config)||'{}');
      return {mode:'manual',gateway:'manual_upi',upi_id:cfg.upi_id,upi_name:cfg.upi_name,amount:order.total,order_number:order.order_number};
    },
    async verify(){ return false; }
  },
  manual_bank: {
    async create(req,order){
      const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get('manual_bank');
      const cfg = JSON.parse(decrypt(r.config)||'{}');
      return {mode:'manual',gateway:'manual_bank',bank:cfg,amount:order.total,order_number:order.order_number};
    },
    async verify(){ return false; }
  }
};
function getActiveGateway(){
  const p = process.env.PAYMENT_PROVIDER || 'manual_upi';
  const r = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get(p);
  if (r && r.enabled) return p;
  const f = db.prepare('SELECT name FROM payment_gateways WHERE enabled=1 ORDER BY id LIMIT 1').get();
  return f ? f.name : 'manual_upi';
}

app.get('/', (req,res)=>{
  const categories = db.prepare('SELECT * FROM categories WHERE visible=1 ORDER BY sort_order,name').all();
  const featured = db.prepare('SELECT p.*, c.name category_name, c.slug category_slug FROM products p JOIN categories c ON c.id=p.category_id WHERE p.featured=1 AND p.status=? ORDER BY p.id DESC LIMIT 6').all('published');
  const popular = db.prepare('SELECT p.*, c.name category_name, c.slug category_slug FROM products p JOIN categories c ON c.id=p.category_id WHERE p.popular=1 AND p.status=? ORDER BY p.id DESC LIMIT 6').all('published');
  const announcements = db.prepare('SELECT * FROM announcements WHERE active=1 ORDER BY id DESC LIMIT 3').all();
  res.render('customer/index', {title: res.locals.settings.site_name+' — '+res.locals.settings.site_tagline, categories, featured, popular, announcements});
});
app.get('/categories', (req,res)=>{ const categories=db.prepare('SELECT * FROM categories WHERE visible=1 ORDER BY sort_order,name').all(); res.render('customer/categories',{title:'Hosting Categories',categories}); });
app.get('/category/:slug', (req,res)=>{
  const cat = db.prepare('SELECT * FROM categories WHERE slug=? AND visible=1').get(req.params.slug);
  if(!cat) return res.status(404).render('customer/404',{title:'Not Found'});
  const products = db.prepare('SELECT * FROM products WHERE category_id=? AND status=? ORDER BY id DESC').all(cat.id,'published');
  res.render('customer/products',{title:cat.name,category:cat,products});
});
app.get('/products', (req,res)=>{
  const q=req.query.q||''; const catFilter=req.query.category||'';
  let sql='SELECT p.*, c.name category_name, c.slug category_slug FROM products p JOIN categories c ON c.id=p.category_id WHERE p.status=?';
  const params=['published'];
  if(q){ sql+=' AND p.name LIKE ?'; params.push('%'+q+'%'); }
  if(catFilter){ sql+=' AND c.slug=?'; params.push(catFilter); }
  sql+=' ORDER BY p.featured DESC, p.id DESC';
  const products = db.prepare(sql).all(...params);
  const categories = db.prepare('SELECT * FROM categories WHERE visible=1 ORDER BY sort_order').all();
  res.render('customer/products',{title:'All Products',products,category:null,categories,q,catFilter});
});
app.get('/product/:slug', (req,res)=>{
  const product = db.prepare('SELECT p.*, c.name category_name, c.slug category_slug FROM products p JOIN categories c ON c.id=p.category_id WHERE p.slug=? AND p.status=?').get(req.params.slug,'published');
  if(!product) return res.status(404).render('customer/404',{title:'Not Found'});
  let features=[]; try{ features=JSON.parse(product.features||'[]'); }catch{}
  const related = db.prepare('SELECT * FROM products WHERE category_id=? AND id!=? AND status=? LIMIT 3').all(product.category_id,product.id,'published');
  res.render('customer/product-details',{title:product.name,product,features,related});
});
app.get('/faq', (req,res)=>res.render('customer/faq',{title:'FAQ'}));
app.get('/about', (req,res)=>res.render('customer/about',{title:'About'}));
app.get('/terms', (req,res)=>res.render('customer/terms',{title:'Terms'}));
app.get('/privacy', (req,res)=>res.render('customer/privacy',{title:'Privacy'}));
app.get('/documentation', (req,res)=>res.render('customer/documentation',{title:'Docs'}));
app.get('/contact', (req,res)=>res.render('customer/contact',{title:'Contact'}));
app.post('/contact', [body('name').trim().isLength({min:2,max:120}),body('email').isEmail().normalizeEmail(),body('message').trim().isLength({min:10,max:5000})], (req,res)=>{
  const e=validationResult(req); if(!e.isEmpty()){ req.flash('error','Please fill the form correctly.'); return res.redirect('/contact'); }
  db.prepare('INSERT INTO contact_messages (name,email,subject,message) VALUES (?,?,?,?)').run(req.body.name,req.body.email,(req.body.subject||'').slice(0,200),req.body.message);
  req.flash('success','Thanks! We will get back to you.'); res.redirect('/contact');
});

app.get('/auth/login', (req,res)=>{ if(req.session.userId) return res.redirect('/dashboard'); res.render('customer/login',{title:'Login',next:req.query.next||''}); });
app.post('/auth/login', authLimiter, [body('email').isEmail().normalizeEmail(),body('password').isLength({min:1})], async (req,res)=>{
  const e=validationResult(req); if(!e.isEmpty()){ req.flash('error','Invalid email or password.'); return res.redirect('/auth/login'); }
  const u = db.prepare('SELECT * FROM users WHERE email=?').get(req.body.email);
  if(!u || u.status!=='active'){ req.flash('error','Invalid credentials or suspended account.'); return res.redirect('/auth/login'); }
  const ok = await bcrypt.compare(req.body.password,u.password_hash);
  if(!ok){ logActivity(u.id,'login_failed','Bad password',req); req.flash('error','Invalid credentials.'); return res.redirect('/auth/login'); }
  req.session.regenerate(err=>{
    if(err){ req.flash('error','Login failed.'); return res.redirect('/auth/login'); }
    req.session.userId = u.id;
    logActivity(u.id,'login','User logged in',req);
    const next = req.body.next || ((u.role==='admin'||u.role==='staff')?'/admin':'/dashboard');
    req.flash('success','Welcome back, '+u.name+'!');
    res.redirect(next);
  });
});
app.get('/auth/register', (req,res)=>{ if(req.session.userId) return res.redirect('/dashboard'); res.render('customer/register',{title:'Create Account'}); });
app.post('/auth/register', authLimiter, [body('name').trim().isLength({min:2,max:120}),body('email').isEmail().normalizeEmail(),body('password').isLength({min:8,max:128})], async (req,res)=>{
  const e=validationResult(req); if(!e.isEmpty()){ req.flash('error','Check inputs. Password must be 8+ chars.'); return res.redirect('/auth/register'); }
  if(db.prepare('SELECT id FROM users WHERE email=?').get(req.body.email)){ req.flash('error','Email already registered.'); return res.redirect('/auth/register'); }
  const h = await bcrypt.hash(req.body.password,12);
  const vt = crypto.randomBytes(24).toString('hex');
  const info = db.prepare('INSERT INTO users (name,email,password_hash,verify_token) VALUES (?,?,?,?)').run(req.body.name,req.body.email,h,vt);
  req.session.userId = info.lastInsertRowid;
  logActivity(info.lastInsertRowid,'register','New user',req);
  sendMail(req.body.email,'Welcome to '+res.locals.settings.site_name,'<p>Verify: '+BASE_URL+'/auth/verify/'+vt+'</p>').catch(()=>{});
  req.flash('success','Account created. Welcome!'); res.redirect('/dashboard');
});
app.get('/auth/verify/:token', (req,res)=>{
  const u = db.prepare('SELECT * FROM users WHERE verify_token=?').get(req.params.token);
  if(!u){ req.flash('error','Invalid link.'); return res.redirect('/'); }
  db.prepare('UPDATE users SET email_verified=1, verify_token=NULL WHERE id=?').run(u.id);
  req.flash('success','Email verified.'); res.redirect('/dashboard');
});
app.get('/auth/forgot-password', (req,res)=>res.render('customer/forgot-password',{title:'Forgot Password'}));
app.post('/auth/forgot-password', authLimiter, [body('email').isEmail().normalizeEmail()], (req,res)=>{
  const u = db.prepare('SELECT * FROM users WHERE email=?').get(req.body.email);
  if(u){ const t=crypto.randomBytes(24).toString('hex'); db.prepare('UPDATE users SET reset_token=?, reset_expires=? WHERE id=?').run(t,Math.floor(Date.now()/1000)+3600,u.id); sendMail(u.email,'Password Reset','<p>Reset: '+BASE_URL+'/auth/reset/'+t+'</p>').catch(()=>{}); }
  req.flash('success','If that email exists, a reset link has been sent.'); res.redirect('/auth/login');
});
app.get('/auth/reset/:token', (req,res)=>{
  const u = db.prepare('SELECT * FROM users WHERE reset_token=? AND reset_expires>?').get(req.params.token,Math.floor(Date.now()/1000));
  if(!u){ req.flash('error','Invalid or expired link.'); return res.redirect('/auth/login'); }
  res.render('customer/reset-password',{title:'Reset Password',token:req.params.token});
});
app.post('/auth/reset/:token', [body('password').isLength({min:8})], async (req,res)=>{
  const u = db.prepare('SELECT * FROM users WHERE reset_token=? AND reset_expires>?').get(req.params.token,Math.floor(Date.now()/1000));
  if(!u){ req.flash('error','Invalid or expired link.'); return res.redirect('/auth/login'); }
  const h = await bcrypt.hash(req.body.password,12);
  db.prepare('UPDATE users SET password_hash=?, reset_token=NULL, reset_expires=NULL WHERE id=?').run(h,u.id);
  req.flash('success','Password reset successfully.'); res.redirect('/auth/login');
});
app.post('/auth/logout', (req,res)=>{ const uid=req.session.userId; req.session.destroy(()=>{ logActivity(uid,'logout','',req); res.redirect('/'); }); });

app.get('/dashboard', requireAuth, (req,res)=>{
  const u = res.locals.currentUser;
  const orders = db.prepare('SELECT * FROM orders WHERE user_id=? ORDER BY id DESC LIMIT 5').all(u.id);
  const services = db.prepare('SELECT * FROM services WHERE user_id=? ORDER BY id DESC LIMIT 5').all(u.id);
  const tickets = db.prepare('SELECT * FROM support_tickets WHERE user_id=? ORDER BY id DESC LIMIT 5').all(u.id);
  const stats = {
    totalOrders: db.prepare('SELECT COUNT(*) c FROM orders WHERE user_id=?').get(u.id).c,
    totalSpent: db.prepare('SELECT COALESCE(SUM(total),0) s FROM orders WHERE user_id=? AND payment_status=?').get(u.id,'paid').s,
    activeServices: db.prepare('SELECT COUNT(*) c FROM services WHERE user_id=? AND status=?').get(u.id,'active').c,
    openTickets: db.prepare('SELECT COUNT(*) c FROM support_tickets WHERE user_id=? AND status!=?').get(u.id,'closed').c
  };
  res.render('customer/dashboard',{title:'Dashboard',orders,services,tickets,stats});
});

app.get('/profile', requireAuth, (req,res)=>res.render('customer/profile',{title:'Profile'}));
app.post('/profile', requireAuth, upload.single('avatar'), (req,res)=>{
  const u = res.locals.currentUser;
  const n = { name:(req.body.name||u.name).trim().slice(0,120), phone:(req.body.phone||'').slice(0,30), address:(req.body.address||'').slice(0,500), city:(req.body.city||'').slice(0,100), country:(req.body.country||'').slice(0,100) };
  if(req.file) n.avatar = '/uploads/'+req.file.filename;
  db.prepare('UPDATE users SET name=?, phone=?, address=?, city=?, country=?, avatar=?, updated_at=? WHERE id=?').run(n.name,n.phone,n.address,n.city,n.country,n.avatar||u.avatar||null,Math.floor(Date.now()/1000),u.id);
  req.flash('success','Profile updated.'); res.redirect('/profile');
});

app.get('/settings', requireAuth, (req,res)=>{ const themes=db.prepare('SELECT * FROM themes WHERE enabled=1 ORDER BY is_default DESC,name').all(); res.render('customer/settings',{title:'Settings',themes}); });
app.post('/settings/password', requireAuth, [body('new_password').isLength({min:8})], async (req,res)=>{
  const u = res.locals.currentUser;
  const full = db.prepare('SELECT * FROM users WHERE id=?').get(u.id);
  if(!(await bcrypt.compare(req.body.current_password||'',full.password_hash))){ req.flash('error','Current password incorrect.'); return res.redirect('/settings'); }
  const h = await bcrypt.hash(req.body.new_password,12);
  db.prepare('UPDATE users SET password_hash=? WHERE id=?').run(h,u.id);
  req.flash('success','Password changed.'); res.redirect('/settings');
});
app.post('/settings/theme', requireAuth, (req,res)=>{ db.prepare('UPDATE users SET theme=? WHERE id=?').run((req.body.theme||'').slice(0,40),res.locals.currentUser.id); req.flash('success','Theme saved.'); res.redirect('/settings'); });

app.get('/cart', (req,res)=>{
  const cart = req.session.cart || [];
  let subtotal=0; cart.forEach(i=>subtotal+=i.price*i.quantity);
  res.render('customer/cart',{title:'Cart',cart,subtotal,discount:0,tax:0,total:subtotal});
});
app.post('/cart/add', (req,res)=>{
  const p = db.prepare('SELECT * FROM products WHERE id=? AND status=?').get(parseInt(req.body.product_id),'published');
  if(!p){ req.flash('error','Product not available.'); return res.redirect('back'); }
  const cycle = ['monthly','quarterly','yearly'].includes(req.body.billing_cycle)?req.body.billing_cycle:'monthly';
  const price = cyclePrice(p,cycle);
  const qty = Math.max(1,Math.min(10,parseInt(req.body.quantity)||1));
  const cart = req.session.cart || [];
  const idx = cart.findIndex(i=>i.product_id===p.id && i.billing_cycle===cycle);
  if(idx>=0) cart[idx].quantity += qty; else cart.push({product_id:p.id,product_name:p.name,price,quantity:qty,billing_cycle:cycle,specs:{cpu:p.cpu,ram:p.ram,storage:p.storage}});
  req.session.cart = cart;
  req.flash('success','Added to cart.'); res.redirect('/cart');
});
app.post('/cart/update/:idx', (req,res)=>{
  const cart = req.session.cart || []; const idx=parseInt(req.params.idx);
  if(cart[idx]){ const q=parseInt(req.body.quantity); if(q<=0) cart.splice(idx,1); else cart[idx].quantity=Math.min(10,q); }
  req.session.cart = cart; res.redirect('/cart');
});
app.post('/cart/remove/:idx', (req,res)=>{ const cart=req.session.cart||[]; cart.splice(parseInt(req.params.idx),1); req.session.cart=cart; res.redirect('/cart'); });
app.post('/cart/apply-coupon', (req,res)=>{
  const code = (req.body.coupon_code||'').toUpperCase().trim();
  const c = db.prepare('SELECT * FROM coupons WHERE code=? AND active=1').get(code);
  if(!c){ req.flash('error','Invalid coupon.'); return res.redirect('/cart'); }
  if(c.expires_at && c.expires_at < Math.floor(Date.now()/1000)){ req.flash('error','Coupon expired.'); return res.redirect('/cart'); }
  if(c.max_uses>0 && c.uses>=c.max_uses){ req.flash('error','Coupon usage limit reached.'); return res.redirect('/cart'); }
  req.session.coupon = {code:c.code,type:c.type,value:c.value};
  req.flash('success','Coupon applied.'); res.redirect('/cart');
});

app.get('/checkout', requireAuth, (req,res)=>{
  const cart = req.session.cart || [];
  if(!cart.length){ req.flash('error','Cart empty.'); return res.redirect('/products'); }
  let subtotal = cart.reduce((s,i)=>s+i.price*i.quantity,0);
  let discount = 0; const coupon = req.session.coupon;
  if(coupon){ discount = coupon.type==='percent' ? subtotal*(coupon.value/100) : Math.min(coupon.value,subtotal); }
  const taxRate = parseFloat(setting('tax_rate','0'))||0;
  const tax = (subtotal-discount)*(taxRate/100);
  const total = subtotal-discount+tax;
  const gateways = db.prepare('SELECT name FROM payment_gateways WHERE enabled=1').all().map(g=>g.name);
  res.render('customer/checkout',{title:'Checkout',cart,subtotal,discount,tax,total,coupon,gateways,activeGateway:getActiveGateway()});
});

app.post('/checkout', requireAuth, async (req,res)=>{
  const cart = req.session.cart || [];
  if(!cart.length){ req.flash('error','Cart empty.'); return res.redirect('/products'); }
  const u = res.locals.currentUser;
  let subtotal = cart.reduce((s,i)=>s+i.price*i.quantity,0);
  let discount = 0; const coupon = req.session.coupon;
  if(coupon){ discount = coupon.type==='percent' ? subtotal*(coupon.value/100) : Math.min(coupon.value,subtotal); }
  const taxRate = parseFloat(setting('tax_rate','0'))||0;
  const tax = (subtotal-discount)*(taxRate/100);
  const total = Math.round((subtotal-discount+tax)*100)/100;
  const gateway = req.body.payment_gateway || getActiveGateway();
  const orderNum = orderNumber();
  const tx = db.transaction(()=>{
    const info = db.prepare(`INSERT INTO orders (order_number,user_id,subtotal,discount,tax,total,currency,coupon_code,billing_cycle,status,payment_status,payment_gateway,notes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(orderNum,u.id,subtotal,discount,tax,total,CURRENCY,coupon?coupon.code:null,cart[0].billing_cycle||'monthly','pending','unpaid',gateway,(req.body.notes||'').slice(0,500));
    const oid = info.lastInsertRowid;
    const insItem = db.prepare('INSERT INTO order_items (order_id,product_id,product_name,price,quantity,billing_cycle,specs) VALUES (?,?,?,?,?,?,?)');
    for(const it of cart) insItem.run(oid,it.product_id,it.product_name,it.price,it.quantity,it.billing_cycle,JSON.stringify(it.specs||{}));
    db.prepare('INSERT INTO invoices (invoice_number,order_id,user_id,amount,currency,status) VALUES (?,?,?,?,?,?)').run(invoiceNumber(),oid,u.id,total,CURRENCY,'unpaid');
    if(coupon) db.prepare('UPDATE coupons SET uses=uses+1 WHERE code=?').run(coupon.code);
    return oid;
  });
  const orderId = tx();
  const order = db.prepare('SELECT * FROM orders WHERE id=?').get(orderId);
  req.session.cart = []; req.session.coupon = null;
  try {
    const adapter = PaymentAdapters[gateway];
    if(!adapter) throw new Error('Gateway not supported');
    const result = await adapter.create(req,order);
    db.prepare('INSERT INTO payments (order_id,gateway,amount,currency,status) VALUES (?,?,?,?,?)').run(orderId,gateway,total,CURRENCY,'pending');
    if(result.mode==='client') return res.render('customer/pay-client',{title:'Processing Payment',result,order});
    if(result.mode==='redirect') return res.redirect(result.url);
    return res.render('customer/pay-manual',{title:'Complete Payment',result,order});
  } catch(err){
    console.error('[checkout]',err);
    req.flash('error','Payment init failed: '+err.message);
    res.redirect('/checkout');
  }
});

app.post('/checkout/razorpay-verify', requireAuth, (req,res)=>{
  const {order_id, razorpay_payment_id} = req.body;
  const order = db.prepare('SELECT * FROM orders WHERE id=? AND user_id=?').get(parseInt(order_id),res.locals.currentUser.id);
  if(!order){ req.flash('error','Order not found.'); return res.redirect('/dashboard'); }
  db.prepare('UPDATE orders SET payment_ref=?, payment_status=?, status=? WHERE id=?').run(razorpay_payment_id,'pending_verification','pending',order.id);
  db.prepare('UPDATE payments SET transaction_id=?, status=? WHERE order_id=?').run(razorpay_payment_id,'pending_verification',order.id);
  req.flash('info','Payment submitted for verification.'); res.redirect('/orders/'+order.id);
});

app.get('/checkout/success', requireAuth, (req,res)=>{
  const o = db.prepare('SELECT * FROM orders WHERE order_number=? AND user_id=?').get(req.query.order,res.locals.currentUser.id);
  if(!o){ req.flash('error','Order not found.'); return res.redirect('/dashboard'); }
  res.render('customer/order-confirmation',{title:'Order Received',order:o});
});
app.get('/checkout/cancel', requireAuth, (req,res)=>{ req.flash('error','Payment cancelled.'); res.redirect('/cart'); });

app.get('/orders', requireAuth, (req,res)=>{ const orders=db.prepare('SELECT * FROM orders WHERE user_id=? ORDER BY id DESC').all(res.locals.currentUser.id); res.render('customer/orders',{title:'Orders',orders}); });
app.get('/orders/:id', requireAuth, (req,res)=>{
  const o = db.prepare('SELECT * FROM orders WHERE id=? AND user_id=?').get(parseInt(req.params.id),res.locals.currentUser.id);
  if(!o) return res.status(404).render('customer/404',{title:'Not Found'});
  const items = db.prepare('SELECT * FROM order_items WHERE order_id=?').all(o.id);
  const payments = db.prepare('SELECT * FROM payments WHERE order_id=? ORDER BY id DESC').all(o.id);
  const invoice = db.prepare('SELECT * FROM invoices WHERE order_id=?').get(o.id);
  res.render('customer/order-details',{title:'Order '+o.order_number,order:o,items,payments,invoice});
});
app.get('/invoices', requireAuth, (req,res)=>{ const invoices=db.prepare('SELECT i.*, o.order_number FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.user_id=? ORDER BY i.id DESC').all(res.locals.currentUser.id); res.render('customer/invoices',{title:'Invoices',invoices}); });
app.get('/invoices/:id', requireAuth, (req,res)=>{
  const inv = db.prepare('SELECT i.*, o.order_number, o.created_at order_date FROM invoices i JOIN orders o ON o.id=i.order_id WHERE i.id=? AND i.user_id=?').get(parseInt(req.params.id),res.locals.currentUser.id);
  if(!inv) return res.status(404).render('customer/404',{title:'Not Found'});
  const items = db.prepare('SELECT * FROM order_items WHERE order_id=?').all(inv.order_id);
  res.render('customer/invoice-view',{title:inv.invoice_number,invoice:inv,items});
});
app.get('/services', requireAuth, (req,res)=>{ const services=db.prepare('SELECT * FROM services WHERE user_id=? ORDER BY id DESC').all(res.locals.currentUser.id); res.render('customer/services',{title:'My Services',services}); });

app.get('/tickets', requireAuth, (req,res)=>{ const tickets=db.prepare('SELECT * FROM support_tickets WHERE user_id=? ORDER BY id DESC').all(res.locals.currentUser.id); res.render('customer/tickets',{title:'Tickets',tickets}); });
app.post('/tickets', requireAuth, [body('subject').trim().isLength({min:3,max:200}),body('message').trim().isLength({min:10,max:5000})], (req,res)=>{
  const e=validationResult(req); if(!e.isEmpty()){ req.flash('error','Subject + message (10+ chars) required.'); return res.redirect('/tickets'); }
  const num = ticketNumber();
  const info = db.prepare('INSERT INTO support_tickets (ticket_number,user_id,subject,category,priority) VALUES (?,?,?,?,?)').run(num,res.locals.currentUser.id,req.body.subject,(req.body.category||'general').slice(0,40),(req.body.priority||'normal').slice(0,20));
  db.prepare('INSERT INTO ticket_messages (ticket_id,user_id,is_admin,message) VALUES (?,?,0,?)').run(info.lastInsertRowid,res.locals.currentUser.id,req.body.message);
  req.flash('success','Ticket created: '+num); res.redirect('/tickets/'+info.lastInsertRowid);
});
app.get('/tickets/:id', requireAuth, (req,res)=>{
  const t = db.prepare('SELECT * FROM support_tickets WHERE id=? AND user_id=?').get(parseInt(req.params.id),res.locals.currentUser.id);
  if(!t) return res.status(404).render('customer/404',{title:'Not Found'});
  const messages = db.prepare('SELECT tm.*, u.name author FROM ticket_messages tm LEFT JOIN users u ON u.id=tm.user_id WHERE tm.ticket_id=? ORDER BY tm.id').all(t.id);
  res.render('customer/ticket-details',{title:'Ticket '+t.ticket_number,ticket:t,messages});
});
app.post('/tickets/:id/reply', requireAuth, [body('message').trim().isLength({min:1,max:5000})], (req,res)=>{
  const t = db.prepare('SELECT * FROM support_tickets WHERE id=? AND user_id=?').get(parseInt(req.params.id),res.locals.currentUser.id);
  if(!t) return res.redirect('/tickets');
  db.prepare('INSERT INTO ticket_messages (ticket_id,user_id,is_admin,message) VALUES (?,?,0,?)').run(t.id,res.locals.currentUser.id,req.body.message);
  db.prepare('UPDATE support_tickets SET status=?, updated_at=? WHERE id=?').run('open',Math.floor(Date.now()/1000),t.id);
  res.redirect('/tickets/'+t.id);
});
app.get('/notifications', requireAuth, (req,res)=>{ const items=db.prepare('SELECT * FROM notifications WHERE user_id=? OR user_id IS NULL ORDER BY id DESC LIMIT 50').all(res.locals.currentUser.id); res.render('customer/notifications',{title:'Notifications',notifications:items}); });

app.get('/admin/login', (req,res)=>{
  if(req.session.userId){ const u=db.prepare('SELECT role FROM users WHERE id=?').get(req.session.userId); if(u && (u.role==='admin'||u.role==='staff')) return res.redirect('/admin'); }
  res.render('admin/login',{title:'Admin Login'});
});
app.post('/admin/login', authLimiter, [body('email').isEmail().normalizeEmail(),body('password').isLength({min:1})], async (req,res)=>{
  const u = db.prepare('SELECT * FROM users WHERE email=?').get(req.body.email);
  if(!u || (u.role!=='admin' && u.role!=='staff')){ req.flash('error','Invalid admin credentials.'); return res.redirect('/admin/login'); }
  if(!(await bcrypt.compare(req.body.password,u.password_hash))){ req.flash('error','Invalid credentials.'); return res.redirect('/admin/login'); }
  req.session.regenerate(err=>{
    if(err){ req.flash('error','Login failed.'); return res.redirect('/admin/login'); }
    req.session.userId = u.id;
    logActivity(u.id,'admin_login','',req);
    res.redirect('/admin');
  });
});

app.get('/admin', requireAdmin, (req,res)=>{
  const stats = {
    totalRevenue: db.prepare("SELECT COALESCE(SUM(total),0) s FROM orders WHERE payment_status='paid'").get().s,
    totalCustomers: db.prepare("SELECT COUNT(*) c FROM users WHERE role='customer'").get().c,
    totalOrders: db.prepare('SELECT COUNT(*) c FROM orders').get().c,
    pendingOrders: db.prepare("SELECT COUNT(*) c FROM orders WHERE status='pending'").get().c,
    completedOrders: db.prepare("SELECT COUNT(*) c FROM orders WHERE status='completed'").get().c,
    activeProducts: db.prepare("SELECT COUNT(*) c FROM products WHERE status='published'").get().c
  };
  const recentOrders = db.prepare('SELECT o.*, u.name customer FROM orders o JOIN users u ON u.id=o.user_id ORDER BY o.id DESC LIMIT 8').all();
  const recentUsers = db.prepare('SELECT id,name,email,created_at FROM users ORDER BY id DESC LIMIT 8').all();
  const recentPayments = db.prepare('SELECT p.*, o.order_number FROM payments p JOIN orders o ON o.id=p.order_id ORDER BY p.id DESC LIMIT 8').all();
  const salesChart = [];
  for(let i=6;i>=0;i--){ const s=Math.floor(Date.now()/1000)-i*86400; const e=s+86400;
    const sum = db.prepare("SELECT COALESCE(SUM(total),0) s FROM orders WHERE payment_status='paid' AND created_at>=? AND created_at<?").get(s,e).s;
    salesChart.push({day:new Date(s*1000).toLocaleDateString(undefined,{weekday:'short'}),total:sum});
  }
  res.render('admin/dashboard',{title:'Admin Dashboard',stats,recentOrders,recentUsers,recentPayments,salesChart});
});

app.get('/admin/categories', requireAdmin, (req,res)=>{ const categories=db.prepare('SELECT * FROM categories ORDER BY sort_order,name').all(); res.render('admin/categories',{title:'Categories',categories}); });
app.post('/admin/categories', requireAdmin, [body('name').trim().isLength({min:2})], (req,res)=>{
  const slug=(req.body.slug||req.body.name).toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
  try{ db.prepare('INSERT INTO categories (name,slug,description,icon,visible,sort_order) VALUES (?,?,?,?,?,?)').run(req.body.name,slug,req.body.description||'',req.body.icon||'fa-folder',req.body.visible?1:0,parseInt(req.body.sort_order)||0); req.flash('success','Category created.'); }
  catch(e){ req.flash('error','Failed: '+e.message); }
  res.redirect('/admin/categories');
});
app.post('/admin/categories/:id', requireAdmin, (req,res)=>{
  const id=parseInt(req.params.id);
  const slug=(req.body.slug||req.body.name).toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
  db.prepare('UPDATE categories SET name=?, slug=?, description=?, icon=?, visible=?, sort_order=? WHERE id=?').run(req.body.name,slug,req.body.description||'',req.body.icon||'',req.body.visible?1:0,parseInt(req.body.sort_order)||0,id);
  req.flash('success','Category updated.'); res.redirect('/admin/categories');
});
app.post('/admin/categories/:id/delete', requireAdmin, (req,res)=>{ db.prepare('DELETE FROM categories WHERE id=?').run(parseInt(req.params.id)); req.flash('success','Category deleted.'); res.redirect('/admin/categories'); });

app.get('/admin/products', requireAdmin, (req,res)=>{ const products=db.prepare('SELECT p.*, c.name category_name FROM products p JOIN categories c ON c.id=p.category_id ORDER BY p.id DESC').all(); res.render('admin/products',{title:'Products',products}); });
app.get('/admin/products/add', requireAdmin, (req,res)=>{ const categories=db.prepare('SELECT * FROM categories ORDER BY name').all(); res.render('admin/product-add',{title:'Add Product',categories}); });
app.post('/admin/products', requireAdmin, upload.single('image'), (req,res)=>{
  try{
    const slug=(req.body.slug||req.body.name).toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
    db.prepare(`INSERT INTO products (category_id,name,slug,description,image,icon,price_monthly,price_quarterly,price_yearly,cpu,ram,storage,bandwidth,network,location,os,features,stock,featured,popular,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(parseInt(req.body.category_id),req.body.name,slug,req.body.description||'',req.file?'/uploads/'+req.file.filename:'',req.body.icon||'',
           parseFloat(req.body.price_monthly)||0, req.body.price_quarterly?parseFloat(req.body.price_quarterly):null, req.body.price_yearly?parseFloat(req.body.price_yearly):null,
           req.body.cpu||'',req.body.ram||'',req.body.storage||'',req.body.bandwidth||'',req.body.network||'',req.body.location||'',req.body.os||'',
           req.body.features||'[]',parseInt(req.body.stock)||-1,req.body.featured?1:0,req.body.popular?1:0,req.body.status||'published');
    req.flash('success','Product created.'); res.redirect('/admin/products');
  } catch(e){ req.flash('error','Failed: '+e.message); res.redirect('/admin/products/add'); }
});
app.get('/admin/products/:id/edit', requireAdmin, (req,res)=>{
  const product = db.prepare('SELECT * FROM products WHERE id=?').get(parseInt(req.params.id));
  if(!product){ req.flash('error','Not found.'); return res.redirect('/admin/products'); }
  const categories = db.prepare('SELECT * FROM categories ORDER BY name').all();
  res.render('admin/product-edit',{title:'Edit Product',product,categories});
});
app.post('/admin/products/:id', requireAdmin, upload.single('image'), (req,res)=>{
  const id = parseInt(req.params.id);
  const existing = db.prepare('SELECT * FROM products WHERE id=?').get(id);
  if(!existing){ req.flash('error','Not found.'); return res.redirect('/admin/products'); }
  const image = req.file ? '/uploads/'+req.file.filename : existing.image;
  db.prepare(`UPDATE products SET category_id=?, name=?, slug=?, description=?, image=?, icon=?, price_monthly=?, price_quarterly=?, price_yearly=?, cpu=?, ram=?, storage=?, bandwidth=?, network=?, location=?, os=?, features=?, stock=?, featured=?, popular=?, status=? WHERE id=?`)
    .run(parseInt(req.body.category_id),req.body.name,req.body.slug||existing.slug,req.body.description||'',image,req.body.icon||'',
         parseFloat(req.body.price_monthly)||0, req.body.price_quarterly?parseFloat(req.body.price_quarterly):null, req.body.price_yearly?parseFloat(req.body.price_yearly):null,
         req.body.cpu||'',req.body.ram||'',req.body.storage||'',req.body.bandwidth||'',req.body.network||'',req.body.location||'',req.body.os||'',
         req.body.features||'[]',parseInt(req.body.stock)||-1,req.body.featured?1:0,req.body.popular?1:0,req.body.status||'published',id);
  req.flash('success','Product updated.'); res.redirect('/admin/products');
});
app.post('/admin/products/:id/delete', requireAdmin, (req,res)=>{ db.prepare('DELETE FROM products WHERE id=?').run(parseInt(req.params.id)); req.flash('success','Product deleted.'); res.redirect('/admin/products'); });

app.get('/admin/customers', requireAdmin, (req,res)=>{
  const q = req.query.q||'';
  const users = q ? db.prepare("SELECT * FROM users WHERE role='customer' AND (name LIKE ? OR email LIKE ?) ORDER BY id DESC").all('%'+q+'%','%'+q+'%')
                  : db.prepare("SELECT * FROM users WHERE role='customer' ORDER BY id DESC").all();
  res.render('admin/customers',{title:'Customers',users,q});
});
app.get('/admin/customers/:id', requireAdmin, (req,res)=>{
  const user = db.prepare('SELECT * FROM users WHERE id=?').get(parseInt(req.params.id));
  if(!user){ req.flash('error','Not found.'); return res.redirect('/admin/customers'); }
  const orders = db.prepare('SELECT * FROM orders WHERE user_id=? ORDER BY id DESC').all(user.id);
  const tickets = db.prepare('SELECT * FROM support_tickets WHERE user_id=? ORDER BY id DESC').all(user.id);
  const services = db.prepare('SELECT * FROM services WHERE user_id=? ORDER BY id DESC').all(user.id);
  res.render('admin/customer-details',{title:'Customer '+user.name,user,orders,tickets,services});
});
app.post('/admin/customers/:id', requireAdmin, (req,res)=>{
  const id = parseInt(req.params.id);
  db.prepare('UPDATE users SET name=?, email=?, status=?, role=? WHERE id=?').run(req.body.name,req.body.email,req.body.status||'active',req.body.role||'customer',id);
  logActivity(req.adminUser.id,'admin_update_customer','User '+id,req);
  req.flash('success','Customer updated.'); res.redirect('/admin/customers/'+id);
});

app.get('/admin/orders', requireAdmin, (req,res)=>{
  const status = req.query.status||'';
  const orders = status ? db.prepare('SELECT o.*, u.name customer, u.email customer_email FROM orders o JOIN users u ON u.id=o.user_id WHERE o.status=? ORDER BY o.id DESC').all(status)
                        : db.prepare('SELECT o.*, u.name customer, u.email customer_email FROM orders o JOIN users u ON u.id=o.user_id ORDER BY o.id DESC').all();
  res.render('admin/orders',{title:'Orders',orders,status});
});
app.get('/admin/orders/:id', requireAdmin, (req,res)=>{
  const o = db.prepare('SELECT o.*, u.name customer, u.email customer_email FROM orders o JOIN users u ON u.id=o.user_id WHERE o.id=?').get(parseInt(req.params.id));
  if(!o){ req.flash('error','Not found.'); return res.redirect('/admin/orders'); }
  const items = db.prepare('SELECT * FROM order_items WHERE order_id=?').all(o.id);
  const payments = db.prepare('SELECT * FROM payments WHERE order_id=? ORDER BY id DESC').all(o.id);
  res.render('admin/order-details',{title:'Order '+o.order_number,order:o,items,payments});
});
app.post('/admin/orders/:id/status', requireAdmin, (req,res)=>{
  const id = parseInt(req.params.id);
  const order = db.prepare('SELECT * FROM orders WHERE id=?').get(id);
  if(!order){ req.flash('error','Not found.'); return res.redirect('/admin/orders'); }
  db.prepare('UPDATE orders SET status=?, payment_status=?, updated_at=? WHERE id=?').run(req.body.status,req.body.payment_status||order.payment_status,Math.floor(Date.now()/1000),id);
  if(req.body.payment_status==='paid' && order.payment_status!=='paid'){
    db.prepare('UPDATE invoices SET status=?, paid_at=? WHERE order_id=?').run('paid',Math.floor(Date.now()/1000),id);
    const items = db.prepare('SELECT * FROM order_items WHERE order_id=?').all(id);
    const insSvc = db.prepare('INSERT INTO services (user_id,order_id,product_name,status,billing_cycle,renews_at,specs) VALUES (?,?,?,?,?,?,?)');
    for(const it of items) insSvc.run(order.user_id,id,it.product_name,'active',it.billing_cycle,Math.floor(Date.now()/1000)+30*86400,it.specs);
  }
  logActivity(req.adminUser.id,'admin_update_order','Order '+order.order_number,req);
  req.flash('success','Order updated.'); res.redirect('/admin/orders/'+id);
});

app.get('/admin/payments', requireAdmin, (req,res)=>{ const payments=db.prepare('SELECT p.*, o.order_number, u.name customer FROM payments p JOIN orders o ON o.id=p.order_id JOIN users u ON u.id=o.user_id ORDER BY p.id DESC').all(); res.render('admin/payments',{title:'Payments',payments}); });
app.get('/admin/payment-settings', requireAdmin, (req,res)=>{
  const gateways = db.prepare('SELECT * FROM payment_gateways ORDER BY id').all().map(g=>({...g,config:JSON.parse(decrypt(g.config)||'{}'),raw_config:g.config}));
  res.render('admin/payment-settings',{title:'Payment Settings',gateways,activeProvider:getActiveGateway()});
});
app.post('/admin/payment-settings/:name', requireAdmin, (req,res)=>{
  const name = req.params.name;
  const existing = db.prepare('SELECT * FROM payment_gateways WHERE name=?').get(name);
  if(!existing){ req.flash('error','Gateway not found.'); return res.redirect('/admin/payment-settings'); }
  const cfg = JSON.parse(decrypt(existing.config)||'{}');
  const fields = ['key_id','key_secret','webhook_secret','secret_key','publishable_key','client_id','client_secret','app_id','upi_id','upi_name','bank_name','account_name','account_number','ifsc','branch'];
  for(const f of fields) if(req.body[f]!==undefined) cfg[f] = req.body[f];
  db.prepare('UPDATE payment_gateways SET enabled=?, mode=?, config=?, updated_at=? WHERE name=?').run(req.body.enabled?1:0,req.body.mode||'test',encrypt(JSON.stringify(cfg)),Math.floor(Date.now()/1000),name);
  req.flash('success',name+' settings saved.'); res.redirect('/admin/payment-settings');
});

app.get('/admin/coupons', requireAdmin, (req,res)=>{ const coupons=db.prepare('SELECT * FROM coupons ORDER BY id DESC').all(); res.render('admin/coupons',{title:'Coupons',coupons}); });
app.post('/admin/coupons', requireAdmin, (req,res)=>{
  try{
    db.prepare('INSERT INTO coupons (code,type,value,min_total,max_uses,active,expires_at) VALUES (?,?,?,?,?,?,?)')
      .run((req.body.code||'').toUpperCase(),req.body.type||'percent',parseFloat(req.body.value)||0,parseFloat(req.body.min_total)||0,parseInt(req.body.max_uses)||0,req.body.active?1:0,req.body.expires_at?Math.floor(new Date(req.body.expires_at).getTime()/1000):null);
    req.flash('success','Coupon created.');
  } catch(e){ req.flash('error',e.message); }
  res.redirect('/admin/coupons');
});
app.post('/admin/coupons/:id/toggle', requireAdmin, (req,res)=>{ const c=db.prepare('SELECT * FROM coupons WHERE id=?').get(parseInt(req.params.id)); if(c) db.prepare('UPDATE coupons SET active=? WHERE id=?').run(c.active?0:1,c.id); res.redirect('/admin/coupons'); });
app.post('/admin/coupons/:id/delete', requireAdmin, (req,res)=>{ db.prepare('DELETE FROM coupons WHERE id=?').run(parseInt(req.params.id)); res.redirect('/admin/coupons'); });

app.get('/admin/invoices', requireAdmin, (req,res)=>{ const invoices=db.prepare('SELECT i.*, o.order_number, u.name customer FROM invoices i JOIN orders o ON o.id=i.order_id JOIN users u ON u.id=i.user_id ORDER BY i.id DESC').all(); res.render('admin/invoices',{title:'Invoices',invoices}); });

app.get('/admin/tickets', requireAdmin, (req,res)=>{ const tickets=db.prepare('SELECT t.*, u.name customer FROM support_tickets t JOIN users u ON u.id=t.user_id ORDER BY t.id DESC').all(); res.render('admin/tickets',{title:'Tickets',tickets}); });
app.get('/admin/tickets/:id', requireAdmin, (req,res)=>{
  const t = db.prepare('SELECT t.*, u.name customer, u.email customer_email FROM support_tickets t JOIN users u ON u.id=t.user_id WHERE t.id=?').get(parseInt(req.params.id));
  if(!t) return res.redirect('/admin/tickets');
  const messages = db.prepare('SELECT tm.*, u.name author FROM ticket_messages tm LEFT JOIN users u ON u.id=tm.user_id WHERE tm.ticket_id=? ORDER BY tm.id').all(t.id);
  res.render('admin/ticket-details',{title:'Ticket '+t.ticket_number,ticket:t,messages});
});
app.post('/admin/tickets/:id/reply', requireAdmin, [body('message').trim().isLength({min:1})], (req,res)=>{
  const t = db.prepare('SELECT * FROM support_tickets WHERE id=?').get(parseInt(req.params.id));
  if(!t) return res.redirect('/admin/tickets');
  db.prepare('INSERT INTO ticket_messages (ticket_id,user_id,is_admin,message) VALUES (?,?,1,?)').run(t.id,req.adminUser.id,req.body.message);
  db.prepare('UPDATE support_tickets SET status=?, updated_at=? WHERE id=?').run(req.body.status||'awaiting',Math.floor(Date.now()/1000),t.id);
  db.prepare('INSERT INTO notifications (user_id,title,message,link) VALUES (?,?,?,?)').run(t.user_id,'Ticket replied','Support replied to '+t.ticket_number,'/tickets/'+t.id);
  res.redirect('/admin/tickets/'+t.id);
});

app.get('/admin/announcements', requireAdmin, (req,res)=>{ const announcements=db.prepare('SELECT * FROM announcements ORDER BY id DESC').all(); res.render('admin/announcements',{title:'Announcements',announcements}); });
app.post('/admin/announcements', requireAdmin, [body('title').trim().isLength({min:2}),body('message').trim().isLength({min:2})], (req,res)=>{
  db.prepare('INSERT INTO announcements (title,message,type,active) VALUES (?,?,?,?)').run(req.body.title,req.body.message,req.body.type||'info',req.body.active?1:0);
  req.flash('success','Announcement created.'); res.redirect('/admin/announcements');
});
app.post('/admin/announcements/:id/delete', requireAdmin, (req,res)=>{ db.prepare('DELETE FROM announcements WHERE id=?').run(parseInt(req.params.id)); res.redirect('/admin/announcements'); });

app.get('/admin/notifications', requireAdmin, (req,res)=>{ const notifications=db.prepare('SELECT * FROM notifications ORDER BY id DESC LIMIT 100').all(); res.render('admin/notifications',{title:'Notifications',notifications}); });
app.post('/admin/notifications', requireAdmin, (req,res)=>{
  db.prepare('INSERT INTO notifications (user_id,title,message,link) VALUES (?,?,?,?)').run(req.body.user_id?parseInt(req.body.user_id):null,req.body.title,req.body.message||'',req.body.link||'');
  req.flash('success','Notification created.'); res.redirect('/admin/notifications');
});

app.get('/admin/themes', requireAdmin, (req,res)=>{
  const themes = db.prepare('SELECT * FROM themes ORDER BY is_default DESC, name').all().map(t=>({...t,vars:JSON.parse(t.variables||'{}')}));
  res.render('admin/themes',{title:'Themes',themes,activeTheme:setting('active_theme','midnight-black')});
});
app.post('/admin/themes/activate', requireAdmin, (req,res)=>{
  const t = db.prepare('SELECT * FROM themes WHERE slug=? AND enabled=1').get(req.body.slug);
  if(!t){ req.flash('error','Theme not available.'); return res.redirect('/admin/themes'); }
  setSetting('active_theme',t.slug);
  req.flash('success','Theme activated: '+t.name); res.redirect('/admin/themes');
});
app.post('/admin/themes/:id/variables', requireAdmin, (req,res)=>{
  const vars = {}; for(const k in req.body) if(k.startsWith('--')) vars[k]=req.body[k];
  db.prepare('UPDATE themes SET variables=? WHERE id=?').run(JSON.stringify(vars),parseInt(req.params.id));
  req.flash('success','Variables saved.'); res.redirect('/admin/themes');
});
app.post('/admin/themes/:id/toggle', requireAdmin, (req,res)=>{ const t=db.prepare('SELECT * FROM themes WHERE id=?').get(parseInt(req.params.id)); if(t) db.prepare('UPDATE themes SET enabled=? WHERE id=?').run(t.enabled?0:1,t.id); res.redirect('/admin/themes'); });

app.get('/admin/animations', requireAdmin, (req,res)=>res.render('admin/animations',{title:'Animation Settings',enabled:setting('animations_enabled','1'),intensity:setting('animation_intensity','medium')}));
app.post('/admin/animations', requireAdmin, (req,res)=>{ setSetting('animations_enabled',req.body.enabled?'1':'0'); setSetting('animation_intensity',req.body.intensity||'medium'); req.flash('success','Saved.'); res.redirect('/admin/animations'); });

app.get('/admin/website-settings', requireAdmin, (req,res)=>{
  const rows = db.prepare('SELECT * FROM website_settings').all();
  const settings = {}; rows.forEach(r=>settings[r.key]=r.value);
  res.render('admin/website-settings',{title:'Website Settings',settings});
});
app.post('/admin/website-settings', requireAdmin, (req,res)=>{
  ['site_name','site_tagline','site_description','discord_invite','contact_email','contact_phone','tax_rate','currency','maintenance_mode'].forEach(k=>{ if(req.body[k]!==undefined) setSetting(k,req.body[k]); });
  req.flash('success','Saved.'); res.redirect('/admin/website-settings');
});

app.get('/admin/seo-settings', requireAdmin, (req,res)=>res.render('admin/seo-settings',{title:'SEO',seo_title:setting('seo_title',''),seo_description:setting('seo_description',''),seo_keywords:setting('seo_keywords','')}));
app.post('/admin/seo-settings', requireAdmin, (req,res)=>{ setSetting('seo_title',req.body.seo_title||''); setSetting('seo_description',req.body.seo_description||''); setSetting('seo_keywords',req.body.seo_keywords||''); req.flash('success','Saved.'); res.redirect('/admin/seo-settings'); });

app.get('/admin/email-settings', requireAdmin, (req,res)=>res.render('admin/email-settings',{title:'Email Settings',smtp_host:process.env.SMTP_HOST||'',smtp_port:process.env.SMTP_PORT||'',smtp_user:process.env.SMTP_USER||''}));
app.get('/admin/security-settings', requireAdmin, (req,res)=>res.render('admin/security-settings',{title:'Security',nodeEnv:NODE_ENV}));
app.get('/admin/navigation', requireAdmin, (req,res)=>res.render('admin/navigation',{title:'Navigation',categories:db.prepare('SELECT * FROM categories ORDER BY sort_order').all()}));

app.get('/admin/staff', requireAdmin, (req,res)=>{ const staff=db.prepare("SELECT id,name,email,role,status,created_at FROM users WHERE role IN ('admin','staff') ORDER BY id").all(); res.render('admin/staff',{title:'Staff',staff}); });
app.post('/admin/staff', requireAdmin, async (req,res)=>{
  try{
    const h = await bcrypt.hash(req.body.password||crypto.randomBytes(12).toString('hex'),12);
    db.prepare('INSERT INTO users (name,email,password_hash,role,email_verified) VALUES (?,?,?,?,1)').run(req.body.name,req.body.email.toLowerCase(),h,req.body.role==='admin'?'admin':'staff');
    req.flash('success','Staff created.');
  } catch(e){ req.flash('error',e.message); }
  res.redirect('/admin/staff');
});
app.post('/admin/staff/:id/delete', requireAdmin, (req,res)=>{ const id=parseInt(req.params.id); if(id===req.adminUser.id){ req.flash('error','Cannot delete yourself.'); return res.redirect('/admin/staff'); } db.prepare('DELETE FROM users WHERE id=? AND role IN (?,?)').run(id,'admin','staff'); res.redirect('/admin/staff'); });

app.get('/admin/activity-logs', requireAdmin, (req,res)=>{ const logs=db.prepare('SELECT l.*, u.name user_name FROM activity_logs l LEFT JOIN users u ON u.id=l.user_id ORDER BY l.id DESC LIMIT 200').all(); res.render('admin/activity-logs',{title:'Activity Logs',logs}); });
app.get('/admin/maintenance', requireAdmin, (req,res)=>res.render('admin/maintenance',{title:'Maintenance',enabled:setting('maintenance_mode','0')==='1'}));
app.post('/admin/maintenance', requireAdmin, (req,res)=>{ setSetting('maintenance_mode',req.body.enabled?'1':'0'); req.flash('success','Maintenance '+(req.body.enabled?'enabled':'disabled')+'.'); res.redirect('/admin/maintenance'); });
app.get('/admin/contact-messages', requireAdmin, (req,res)=>{ const messages=db.prepare('SELECT * FROM contact_messages ORDER BY id DESC').all(); res.render('admin/contact-messages',{title:'Contact Messages',messages}); });

app.get('/api/categories', (req,res)=>res.json(db.prepare('SELECT id,name,slug,icon FROM categories WHERE visible=1 ORDER BY sort_order').all()));
app.get('/api/products', (req,res)=>res.json(db.prepare('SELECT id,name,slug,price_monthly FROM products WHERE status=? ORDER BY id DESC').all('published')));

app.use((req,res)=>res.status(404).render('customer/404',{title:'Not Found'}));
app.use((err,req,res,next)=>{
  console.error('[error]',err);
  if(err.code==='EBADCSRFTOKEN'){ req.flash('error','Security token expired. Retry.'); return res.redirect(req.get('referer')||'/'); }
  if(req.path.startsWith('/admin')) return res.status(500).send('<h1>Admin Error</h1><p>'+(NODE_ENV==='production'?'Something went wrong.':err.message)+'</p><pre style="color:#999;font-size:12px;white-space:pre-wrap;">'+(NODE_ENV==='production'?'':err.stack)+'</pre>');
  res.status(500).render('customer/404',{title:'Error'});
});

app.listen(PORT, ()=>{
  console.log(`\n  ╔══════════════════════════════════════════╗`);
  console.log(`  ║  AG TECH HOSTING — SERVER STARTED        ║`);
  console.log(`  ║  URL:   ${BASE_URL}`);
  console.log(`  ║  Admin: ${BASE_URL}/admin/login`);
  console.log(`  ║  Env:   ${NODE_ENV}`);
  console.log(`  ╚══════════════════════════════════════════╝\n`);
});

process.on('SIGINT',()=>{ console.log('\nShutting down...'); db.close(); process.exit(0); });
AGH_APP_EOF
log "app.js written ($(wc -l < app.js) lines)"

# ============================================================
# 6. CSS
# ============================================================
step "Writing CSS files"
cat > public/css/style.css <<'AGH_STYLE_EOF'
:root{--bg:#0a0a0f;--bg-2:#0f0f18;--card:#12121c;--primary:#8b5cf6;--primary-2:#a855f7;--text:#e8e8f0;--muted:#8b8ba0;--border:#1f1f2e;--gradient:linear-gradient(135deg,#8b5cf6,#a855f7);--success:#10b981;--error:#ef4444;--warning:#f59e0b;--info:#3b82f6;--radius:14px;--radius-sm:8px;--radius-lg:20px;--shadow:0 10px 40px rgba(139,92,246,.15);--shadow-lg:0 20px 60px rgba(139,92,246,.3);--font:'Inter',-apple-system,sans-serif;--transition:.3s cubic-bezier(.4,0,.2,1)}
*{box-sizing:border-box;margin:0;padding:0}html{scroll-behavior:smooth}
body{font-family:var(--font);background:var(--bg);color:var(--text);line-height:1.6;overflow-x:hidden;min-height:100vh;-webkit-font-smoothing:antialiased}
a{color:var(--primary);text-decoration:none;transition:color var(--transition)}a:hover{color:var(--primary-2)}
img{max-width:100%;height:auto;display:block}button{font-family:inherit;cursor:pointer}
.bg-particles{position:fixed;top:0;left:0;width:100%;height:100%;z-index:-1;overflow:hidden;pointer-events:none}
.bg-particles .particle{position:absolute;width:4px;height:4px;background:var(--primary);border-radius:50%;opacity:.4;animation:float-up 15s infinite linear;box-shadow:0 0 10px var(--primary)}
@keyframes float-up{0%{transform:translateY(100vh);opacity:0}10%{opacity:.6}90%{opacity:.6}100%{transform:translateY(-10vh);opacity:0}}
.navbar{position:sticky;top:0;z-index:100;background:rgba(10,10,15,.85);backdrop-filter:blur(20px);border-bottom:1px solid var(--border);transition:all var(--transition)}
.navbar.scrolled{background:rgba(10,10,15,.98);box-shadow:0 4px 30px rgba(0,0,0,.4)}
.nav-container{max-width:1400px;margin:0 auto;padding:0 24px;display:flex;align-items:center;justify-content:space-between;height:72px}
.nav-logo{display:flex;align-items:center;gap:10px;font-size:1.35rem;font-weight:800;color:var(--text)}
.nav-logo .logo-icon{width:38px;height:38px;background:var(--gradient);border-radius:10px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;box-shadow:0 0 20px rgba(139,92,246,.5)}
.nav-menu{display:flex;align-items:center;gap:4px;list-style:none}
.nav-menu a{color:var(--muted);padding:8px 14px;border-radius:var(--radius-sm);font-size:.92rem;font-weight:500;transition:all var(--transition)}
.nav-menu a:hover,.nav-menu a.active{color:var(--text);background:rgba(139,92,246,.1)}
.nav-actions{display:flex;align-items:center;gap:12px}
.nav-toggle{display:none;background:none;border:1px solid var(--border);color:var(--text);width:42px;height:42px;border-radius:var(--radius-sm);font-size:1.2rem}
.cart-badge{position:relative}.cart-badge .badge{position:absolute;top:-6px;right:-8px;background:var(--primary);color:#fff;font-size:.7rem;font-weight:700;min-width:18px;height:18px;border-radius:50%;display:flex;align-items:center;justify-content:center;padding:0 4px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:12px 24px;border-radius:var(--radius-sm);font-weight:600;font-size:.92rem;border:none;transition:all var(--transition);text-decoration:none;cursor:pointer;position:relative;overflow:hidden}
.btn-primary{background:var(--gradient);color:#fff;box-shadow:0 4px 20px rgba(139,92,246,.4)}
.btn-primary:hover{transform:translateY(-2px);box-shadow:0 8px 30px rgba(139,92,246,.6);color:#fff}
.btn-outline{background:transparent;color:var(--text);border:1px solid var(--border)}
.btn-outline:hover{border-color:var(--primary);color:var(--primary);background:rgba(139,92,246,.05)}
.btn-ghost{background:rgba(139,92,246,.1);color:var(--primary)}
.btn-ghost:hover{background:rgba(139,92,246,.2)}
.btn-danger{background:var(--error);color:#fff}
.btn-danger:hover{background:#dc2626}
.btn-block{width:100%}.btn-sm{padding:8px 16px;font-size:.85rem}.btn-lg{padding:16px 32px;font-size:1rem}
.flash-container{position:fixed;top:88px;right:24px;z-index:200;display:flex;flex-direction:column;gap:10px;max-width:380px}
.flash{padding:14px 20px;border-radius:var(--radius-sm);background:var(--card);border-left:4px solid var(--primary);box-shadow:var(--shadow);animation:slideIn .4s ease;font-size:.9rem}
.flash.success{border-left-color:var(--success)}.flash.error{border-left-color:var(--error)}.flash.info{border-left-color:var(--info)}
@keyframes slideIn{from{transform:translateX(400px);opacity:0}to{transform:translateX(0);opacity:1}}
.hero{position:relative;padding:100px 24px 120px;text-align:center;overflow:hidden;background:radial-gradient(ellipse at top,rgba(139,92,246,.15),transparent 60%)}
.hero::before{content:'';position:absolute;top:-50%;left:50%;transform:translateX(-50%);width:800px;height:800px;background:radial-gradient(circle,rgba(139,92,246,.15),transparent 70%);animation:pulse-glow 4s ease-in-out infinite;pointer-events:none}
@keyframes pulse-glow{0%,100%{transform:translateX(-50%) scale(1);opacity:.6}50%{transform:translateX(-50%) scale(1.15);opacity:1}}
.hero-content{position:relative;z-index:1;max-width:900px;margin:0 auto}
.hero-badge{display:inline-flex;align-items:center;gap:8px;padding:8px 18px;background:rgba(139,92,246,.12);border:1px solid rgba(139,92,246,.3);border-radius:50px;font-size:.85rem;color:var(--primary-2);margin-bottom:24px}
.hero-badge .dot{width:8px;height:8px;background:var(--success);border-radius:50%;box-shadow:0 0 10px var(--success);animation:blink 2s infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.4}}
.hero h1{font-size:clamp(2.2rem,5.5vw,4.2rem);font-weight:900;line-height:1.1;letter-spacing:-2px;margin-bottom:20px}
.hero h1 .gradient-text{background:var(--gradient);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}
.hero p{font-size:clamp(1rem,2vw,1.2rem);color:var(--muted);max-width:640px;margin:0 auto 36px}
.hero-actions{display:flex;gap:14px;justify-content:center;flex-wrap:wrap}
.hero-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:20px;max-width:800px;margin:70px auto 0}
.hero-stat{padding:24px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);transition:all var(--transition)}
.hero-stat:hover{border-color:var(--primary);transform:translateY(-4px);box-shadow:var(--shadow)}
.hero-stat .num{font-size:2rem;font-weight:800;background:var(--gradient);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
.hero-stat .label{font-size:.85rem;color:var(--muted);margin-top:4px}
.section{padding:80px 24px;max-width:1400px;margin:0 auto}
.section-header{text-align:center;margin-bottom:56px}
.section-header h2{font-size:clamp(1.8rem,3.5vw,2.6rem);font-weight:800;letter-spacing:-1px;margin-bottom:12px}
.section-header p{color:var(--muted);max-width:600px;margin:0 auto;font-size:1.05rem}
.section-tag{display:inline-block;padding:6px 16px;background:rgba(139,92,246,.12);color:var(--primary-2);border-radius:50px;font-size:.8rem;font-weight:600;text-transform:uppercase;letter-spacing:1px;margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:28px;transition:all var(--transition)}
.card:hover{border-color:var(--primary);box-shadow:var(--shadow)}
.grid{display:grid;gap:24px}.grid-2{grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
.grid-3{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}.grid-4{grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.category-card{display:block;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:28px;text-align:center;color:var(--text);position:relative;overflow:hidden;transition:all var(--transition)}
.category-card:hover{transform:translateY(-6px);border-color:var(--primary);box-shadow:var(--shadow-lg)}
.category-card .cat-icon{width:64px;height:64px;margin:0 auto 18px;background:var(--gradient);border-radius:16px;display:flex;align-items:center;justify-content:center;color:#fff;font-size:1.6rem;box-shadow:0 8px 24px rgba(139,92,246,.4)}
.category-card h3{font-size:1.1rem;font-weight:700;margin-bottom:8px;color:var(--text)}
.category-card p{color:var(--muted);font-size:.88rem}
.product-card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden;display:flex;flex-direction:column;transition:all var(--transition);position:relative}
.product-card:hover{border-color:var(--primary);box-shadow:var(--shadow-lg);transform:translateY(-6px)}
.product-card .ribbon{position:absolute;top:14px;right:14px;padding:4px 12px;background:var(--gradient);color:#fff;font-size:.7rem;font-weight:700;border-radius:50px;text-transform:uppercase;z-index:2}
.product-card .ribbon.popular{background:linear-gradient(135deg,#f59e0b,#fbbf24)}
.product-img{width:100%;height:160px;object-fit:cover}
.product-img-placeholder{width:100%;height:160px;display:flex;align-items:center;justify-content:center;font-size:3rem;color:var(--primary);background:linear-gradient(135deg,rgba(139,92,246,.15),rgba(168,85,247,.05))}
.product-body{padding:20px;flex:1;display:flex;flex-direction:column}
.product-cat{font-size:.72rem;color:var(--primary-2);text-transform:uppercase;letter-spacing:1px;font-weight:700;margin-bottom:6px}
.product-body h3{font-size:1.15rem;font-weight:700;margin-bottom:10px}
.product-body .desc{color:var(--muted);font-size:.85rem;margin-bottom:16px;flex:1}
.product-specs{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-bottom:16px}
.product-specs .spec{display:flex;align-items:center;gap:6px;font-size:.78rem;color:var(--muted)}
.product-specs .spec i{color:var(--primary);width:14px}
.product-price{display:flex;align-items:baseline;gap:4px;margin-bottom:14px}
.product-price .amount{font-size:1.7rem;font-weight:800;color:var(--text)}
.product-price .period{font-size:.85rem;color:var(--muted)}
.product-detail-hero{display:grid;grid-template-columns:1fr 1fr;gap:40px;padding:60px 24px;max-width:1200px;margin:0 auto}
@media(max-width:900px){.product-detail-hero{grid-template-columns:1fr}}
.product-spec-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;margin:24px 0}
.spec-item{padding:16px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius-sm)}
.spec-item .label{font-size:.75rem;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:4px}
.spec-item .value{font-weight:700;font-size:1rem}
.form-group{margin-bottom:18px}
.form-label{display:block;font-size:.88rem;font-weight:600;margin-bottom:8px;color:var(--text)}
.form-input,.form-select,.form-textarea{width:100%;padding:12px 16px;background:var(--bg-2);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);font-size:.92rem;font-family:inherit;transition:all var(--transition)}
.form-input:focus,.form-select:focus,.form-textarea:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 3px rgba(139,92,246,.15)}
.form-textarea{resize:vertical;min-height:100px}
.form-hint{font-size:.78rem;color:var(--muted);margin-top:6px}
.form-checkbox{display:flex;align-items:center;gap:8px}
.form-checkbox input[type="checkbox"]{width:18px;height:18px;accent-color:var(--primary)}
.auth-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px 20px}
.auth-card{width:100%;max-width:440px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius-lg);padding:44px 36px;box-shadow:var(--shadow-lg)}
.auth-card h1{text-align:center;font-size:1.6rem;margin-bottom:8px}
.auth-card .subtitle{text-align:center;color:var(--muted);margin-bottom:30px;font-size:.9rem}
.auth-card .logo{display:flex;justify-content:center;margin-bottom:24px}
.auth-footer{text-align:center;margin-top:24px;font-size:.88rem;color:var(--muted)}
.table-wrap{overflow-x:auto;background:var(--card);border:1px solid var(--border);border-radius:var(--radius)}
.table{width:100%;border-collapse:collapse;min-width:600px}
.table th{padding:14px 16px;text-align:left;font-size:.78rem;text-transform:uppercase;letter-spacing:1px;color:var(--muted);border-bottom:1px solid var(--border);font-weight:600}
.table td{padding:14px 16px;border-bottom:1px solid var(--border);font-size:.88rem}
.table tr:last-child td{border-bottom:none}
.table tr:hover{background:rgba(139,92,246,.04)}
.badge{display:inline-block;padding:4px 10px;border-radius:50px;font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.5px}
.badge-success{background:rgba(16,185,129,.15);color:var(--success)}
.badge-warning{background:rgba(245,158,11,.15);color:var(--warning)}
.badge-error{background:rgba(239,68,68,.15);color:var(--error)}
.badge-info{background:rgba(59,130,246,.15);color:var(--info)}
.badge-primary{background:rgba(139,92,246,.15);color:var(--primary)}
.dash-wrap{max-width:1400px;margin:0 auto;padding:40px 24px;display:grid;grid-template-columns:260px 1fr;gap:30px}
@media(max-width:900px){.dash-wrap{grid-template-columns:1fr}}
.dash-sidebar{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:20px;height:fit-content;position:sticky;top:92px}
.dash-sidebar .profile{text-align:center;padding-bottom:20px;border-bottom:1px solid var(--border);margin-bottom:16px}
.dash-sidebar .avatar{width:72px;height:72px;border-radius:50%;margin:0 auto 12px;background:var(--gradient);display:flex;align-items:center;justify-content:center;font-size:1.6rem;color:#fff;font-weight:800;overflow:hidden}
.dash-sidebar .avatar img{width:100%;height:100%;object-fit:cover}
.dash-nav{display:flex;flex-direction:column;gap:4px}
.dash-nav a{padding:10px 14px;border-radius:var(--radius-sm);color:var(--muted);font-size:.9rem;display:flex;align-items:center;gap:10px;transition:all var(--transition)}
.dash-nav a:hover,.dash-nav a.active{background:rgba(139,92,246,.1);color:var(--primary)}
.dash-content h1{font-size:1.8rem;margin-bottom:24px}
.stat-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:18px;margin-bottom:30px}
.stat-card{padding:22px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);position:relative;overflow:hidden}
.stat-card::before{content:'';position:absolute;top:0;left:0;right:0;height:3px;background:var(--gradient)}
.stat-card .icon{width:40px;height:40px;background:rgba(139,92,246,.15);color:var(--primary);border-radius:10px;display:flex;align-items:center;justify-content:center;margin-bottom:14px;font-size:1.1rem}
.stat-card .value{font-size:1.7rem;font-weight:800}
.stat-card .label{color:var(--muted);font-size:.85rem;margin-top:4px}
.cart-grid{display:grid;grid-template-columns:1fr 380px;gap:30px;padding:40px 24px;max-width:1200px;margin:0 auto}
@media(max-width:900px){.cart-grid{grid-template-columns:1fr}}
.cart-item{display:flex;gap:16px;padding:20px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);margin-bottom:12px;flex-wrap:wrap}
.cart-item .item-info{flex:1;min-width:180px}
.cart-item h3{font-size:1rem;margin-bottom:4px}
.cart-item .item-meta{font-size:.8rem;color:var(--muted)}
.cart-summary{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:24px;height:fit-content;position:sticky;top:92px}
.cart-summary h2{font-size:1.15rem;margin-bottom:20px}
.summary-row{display:flex;justify-content:space-between;padding:10px 0;font-size:.9rem;border-bottom:1px solid var(--border)}
.summary-row.total{font-size:1.15rem;font-weight:800;border-top:2px solid var(--border);border-bottom:none;margin-top:10px;padding-top:16px}
.footer{background:var(--bg-2);border-top:1px solid var(--border);padding:60px 24px 30px;margin-top:80px}
.footer-inner{max-width:1400px;margin:0 auto}
.footer-grid{display:grid;grid-template-columns:2fr 1fr 1fr 1fr;gap:40px;margin-bottom:40px}
@media(max-width:800px){.footer-grid{grid-template-columns:1fr 1fr}}
@media(max-width:500px){.footer-grid{grid-template-columns:1fr}}
.footer-brand{display:flex;align-items:center;gap:10px;margin-bottom:12px;font-size:1.2rem;font-weight:800}
.footer p{color:var(--muted);font-size:.88rem;line-height:1.8}
.footer h4{font-size:.9rem;text-transform:uppercase;letter-spacing:1px;margin-bottom:16px;color:var(--text)}
.footer ul{list-style:none}.footer ul li{margin-bottom:10px}
.footer ul a{color:var(--muted);font-size:.88rem}
.footer ul a:hover{color:var(--primary)}
.footer-bottom{text-align:center;padding-top:24px;border-top:1px solid var(--border);color:var(--muted);font-size:.85rem}
.discord-btn{display:inline-flex;align-items:center;gap:8px;padding:10px 20px;background:#5865F2;color:#fff;border-radius:var(--radius-sm);font-weight:600;font-size:.88rem;margin-top:12px}
.discord-btn:hover{background:#4752c4;color:#fff;transform:translateY(-2px)}
.faq-item{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);margin-bottom:12px;overflow:hidden;transition:all var(--transition)}
.faq-item:hover{border-color:var(--primary)}
.faq-q{padding:20px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;font-weight:600;font-size:.95rem}
.faq-a{max-height:0;overflow:hidden;padding:0 20px;color:var(--muted);font-size:.9rem;transition:all var(--transition)}
.faq-item.open .faq-a{max-height:400px;padding:0 20px 20px}
.faq-item.open .faq-q i{transform:rotate(180deg)}
.faq-q i{transition:transform var(--transition);color:var(--primary)}
.announcement-banner{background:rgba(139,92,246,.1);border:1px solid rgba(139,92,246,.3);border-radius:var(--radius);padding:14px 20px;margin-bottom:20px;display:flex;align-items:center;gap:12px;font-size:.9rem}
.announcement-banner i{color:var(--primary)}
.testimonial{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:26px}
.testimonial .stars{color:#fbbf24;margin-bottom:14px}
.testimonial .quote{font-style:italic;color:var(--text);margin-bottom:18px;font-size:.92rem;line-height:1.7}
.testimonial .author{display:flex;align-items:center;gap:12px}
.testimonial .author .av{width:40px;height:40px;border-radius:50%;background:var(--gradient);display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700}
.testimonial .author strong{display:block;font-size:.9rem}
.testimonial .author span{font-size:.8rem;color:var(--muted)}
.feature{display:flex;gap:16px;padding:20px}
.feature .icon{flex-shrink:0;width:48px;height:48px;background:rgba(139,92,246,.12);border-radius:12px;display:flex;align-items:center;justify-content:center;color:var(--primary);font-size:1.2rem}
.feature h3{font-size:1rem;margin-bottom:6px}
.feature p{color:var(--muted);font-size:.88rem}
.location{padding:20px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);text-align:center}
.location .flag{font-size:2rem;margin-bottom:8px}
.location h4{font-size:1rem;margin-bottom:4px}
.location p{font-size:.8rem;color:var(--muted)}
.empty-state{text-align:center;padding:60px 24px;color:var(--muted)}
.empty-state i{font-size:3rem;margin-bottom:16px;color:var(--border)}
.empty-state h3{font-size:1.2rem;color:var(--text);margin-bottom:8px}
.empty-state p{font-size:.9rem;margin-bottom:20px}
.reveal{opacity:0;transform:translateY(30px);transition:all .6s ease}
.reveal.visible{opacity:1;transform:translateY(0)}
body.no-animations *,body.no-animations *::before,body.no-animations *::after{animation:none!important;transition:none!important}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;transition-duration:.01ms!important}}
.container{max-width:1400px;margin:0 auto;padding:0 24px}
.text-center{text-align:center}.text-muted{color:var(--muted)}
.mt-1{margin-top:8px}.mt-2{margin-top:16px}.mt-3{margin-top:24px}.mt-4{margin-top:32px}
.mb-1{margin-bottom:8px}.mb-2{margin-bottom:16px}.mb-3{margin-bottom:24px}.mb-4{margin-bottom:32px}
.flex{display:flex}.items-center{align-items:center}.justify-between{justify-content:space-between}.gap-2{gap:16px}
.flex-wrap{flex-wrap:wrap}.w-full{width:100%}
@media(max-width:900px){
  .nav-menu{position:fixed;top:72px;left:0;right:0;background:var(--bg-2);border-bottom:1px solid var(--border);flex-direction:column;padding:20px;transform:translateY(-120%);transition:transform var(--transition);box-shadow:0 10px 30px rgba(0,0,0,.4)}
  .nav-menu.open{transform:translateY(0)}
  .nav-menu a{width:100%;padding:14px}
  .nav-toggle{display:flex;align-items:center;justify-content:center}
  .nav-actions .btn span{display:none}
}
AGH_STYLE_EOF

cat > public/css/admin.css <<'AGH_ADMIN_EOF'
:root{--bg:#08080d;--bg-2:#0d0d15;--card:#11111b;--sidebar:#0b0b12;--primary:#8b5cf6;--primary-2:#a855f7;--text:#e8e8f0;--muted:#7a7a90;--border:#1a1a28;--gradient:linear-gradient(135deg,#8b5cf6,#a855f7);--success:#10b981;--error:#ef4444;--warning:#f59e0b;--info:#3b82f6;--radius:12px;--radius-sm:8px;--shadow:0 8px 30px rgba(0,0,0,.3);--font:'Inter',-apple-system,sans-serif;--transition:.25s ease}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh;font-size:14px}
a{color:var(--primary);text-decoration:none}a:hover{color:var(--primary-2)}
img{max-width:100%;display:block}
.admin-layout{display:grid;grid-template-columns:260px 1fr;min-height:100vh}
@media(max-width:900px){.admin-layout{grid-template-columns:1fr}}
.sidebar{background:var(--sidebar);border-right:1px solid var(--border);padding:20px 16px;position:sticky;top:0;height:100vh;overflow-y:auto}
@media(max-width:900px){.sidebar{position:fixed;left:0;top:0;z-index:200;transform:translateX(-100%);transition:transform var(--transition);width:260px}.sidebar.open{transform:translateX(0)}.sidebar-overlay{position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:199;display:none}.sidebar-overlay.open{display:block}}
.sidebar-brand{display:flex;align-items:center;gap:10px;padding:8px 12px 24px;border-bottom:1px solid var(--border);margin-bottom:20px;font-size:1.1rem;font-weight:800}
.sidebar-brand .logo-icon{width:36px;height:36px;background:var(--gradient);border-radius:9px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;font-size:.95rem;box-shadow:0 0 15px rgba(139,92,246,.5)}
.sidebar-section{font-size:.68rem;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted);font-weight:700;padding:16px 12px 8px}
.sidebar-nav{display:flex;flex-direction:column;gap:2px}
.sidebar-nav a{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:var(--radius-sm);color:var(--muted);font-size:.88rem;font-weight:500;transition:all var(--transition)}
.sidebar-nav a:hover{background:rgba(139,92,246,.08);color:var(--text)}
.sidebar-nav a.active{background:rgba(139,92,246,.15);color:var(--primary-2);border-left:3px solid var(--primary)}
.sidebar-nav a i{width:18px;text-align:center;font-size:.95rem}
.admin-main{display:flex;flex-direction:column;min-height:100vh}
.admin-header{background:var(--bg-2);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:100}
.admin-header .menu-toggle{display:none;background:none;border:1px solid var(--border);color:var(--text);width:38px;height:38px;border-radius:var(--radius-sm)}
@media(max-width:900px){.admin-header .menu-toggle{display:flex;align-items:center;justify-content:center}}
.header-title h1{font-size:1.2rem;font-weight:700}
.header-title .crumb{font-size:.75rem;color:var(--muted)}
.header-actions{display:flex;align-items:center;gap:14px}
.header-actions .user-chip{display:flex;align-items:center;gap:10px;padding:6px 12px 6px 6px;background:var(--card);border:1px solid var(--border);border-radius:50px;font-size:.85rem}
.header-actions .user-chip .av{width:30px;height:30px;border-radius:50%;background:var(--gradient);display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700;font-size:.85rem}
.admin-content{padding:24px;flex:1;max-width:1600px;width:100%;margin:0 auto}
.page-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:22px;flex-wrap:wrap;gap:12px}
.page-header h1{font-size:1.5rem;font-weight:800}
.page-header p{color:var(--muted);font-size:.85rem;margin-top:4px}
.card{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:20px}
.card-title{font-size:1rem;font-weight:700;margin-bottom:16px}
.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:24px}
.stat-box{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:20px;position:relative;overflow:hidden}
.stat-box::after{content:'';position:absolute;top:0;right:0;width:80px;height:80px;background:radial-gradient(circle,rgba(139,92,246,.15),transparent 70%)}
.stat-box .lbl{font-size:.78rem;color:var(--muted);text-transform:uppercase;letter-spacing:1px;font-weight:600;margin-bottom:8px}
.stat-box .val{font-size:1.8rem;font-weight:800}
.stat-box .sub{font-size:.75rem;color:var(--muted);margin-top:4px}
.stat-box.primary .val{color:var(--primary-2)}
.stat-box.success .val{color:var(--success)}
.stat-box.warning .val{color:var(--warning)}
.table-wrap{overflow-x:auto;background:var(--card);border:1px solid var(--border);border-radius:var(--radius)}
.table{width:100%;border-collapse:collapse;min-width:700px}
.table th{padding:12px 16px;text-align:left;font-size:.72rem;text-transform:uppercase;letter-spacing:1px;color:var(--muted);border-bottom:1px solid var(--border);font-weight:700;background:var(--bg-2)}
.table td{padding:12px 16px;border-bottom:1px solid var(--border);font-size:.85rem;vertical-align:middle}
.table tr:last-child td{border-bottom:none}
.table tbody tr:hover{background:rgba(139,92,246,.03)}
.table .actions{display:flex;gap:6px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;padding:9px 16px;border-radius:var(--radius-sm);font-weight:600;font-size:.82rem;border:none;cursor:pointer;transition:all var(--transition);text-decoration:none;font-family:inherit}
.btn-primary{background:var(--gradient);color:#fff}
.btn-primary:hover{box-shadow:0 4px 15px rgba(139,92,246,.4);color:#fff;transform:translateY(-1px)}
.btn-outline{background:transparent;border:1px solid var(--border);color:var(--text)}
.btn-outline:hover{border-color:var(--primary);color:var(--primary)}
.btn-danger{background:var(--error);color:#fff}
.btn-danger:hover{background:#dc2626}
.btn-success{background:var(--success);color:#fff}
.btn-sm{padding:5px 10px;font-size:.75rem}
.btn-block{width:100%}
.badge{display:inline-block;padding:3px 9px;border-radius:50px;font-size:.68rem;font-weight:700;text-transform:uppercase;letter-spacing:.5px}
.badge-success{background:rgba(16,185,129,.15);color:var(--success)}
.badge-warning{background:rgba(245,158,11,.15);color:var(--warning)}
.badge-error{background:rgba(239,68,68,.15);color:var(--error)}
.badge-info{background:rgba(59,130,246,.15);color:var(--info)}
.badge-primary{background:rgba(139,92,246,.15);color:var(--primary-2)}
.form-group{margin-bottom:16px}
.form-label{display:block;font-size:.82rem;font-weight:600;margin-bottom:6px}
.form-input,.form-select,.form-textarea{width:100%;padding:10px 14px;background:var(--bg-2);border:1px solid var(--border);border-radius:var(--radius-sm);color:var(--text);font-size:.87rem;font-family:inherit;transition:all var(--transition)}
.form-input:focus,.form-select:focus,.form-textarea:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 3px rgba(139,92,246,.15)}
.form-textarea{resize:vertical;min-height:90px}
.form-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px}
.form-checkbox{display:flex;align-items:center;gap:8px;font-size:.85rem}
.form-checkbox input{width:16px;height:16px;accent-color:var(--primary)}
.flash-container{position:fixed;top:20px;right:20px;z-index:9999;display:flex;flex-direction:column;gap:10px;max-width:360px}
.flash{padding:12px 18px;border-radius:var(--radius-sm);background:var(--card);border-left:4px solid var(--primary);box-shadow:var(--shadow);font-size:.85rem;animation:slideIn .3s ease}
.flash.success{border-left-color:var(--success)}.flash.error{border-left-color:var(--error)}.flash.info{border-left-color:var(--info)}
@keyframes slideIn{from{transform:translateX(400px);opacity:0}to{transform:translateX(0);opacity:1}}
.admin-login-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;background:radial-gradient(circle at top,rgba(139,92,246,.15),transparent 60%)}
.admin-login-card{width:100%;max-width:400px;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:36px 30px;box-shadow:var(--shadow)}
.admin-login-card h1{text-align:center;font-size:1.3rem;margin-bottom:6px}
.admin-login-card .sub{text-align:center;color:var(--muted);font-size:.85rem;margin-bottom:26px}
.admin-login-card .logo{display:flex;justify-content:center;margin-bottom:20px}
.admin-login-card .logo .logo-icon{width:52px;height:52px;background:var(--gradient);border-radius:12px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;font-size:1.2rem;box-shadow:0 0 30px rgba(139,92,246,.5)}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--border);margin-bottom:20px;overflow-x:auto}
.tabs a{padding:10px 16px;color:var(--muted);font-size:.85rem;font-weight:600;border-bottom:2px solid transparent;white-space:nowrap}
.tabs a.active,.tabs a:hover{color:var(--primary);border-bottom-color:var(--primary)}
.bar-chart{display:flex;align-items:flex-end;gap:12px;height:220px;padding:10px 0}
.bar-chart .bar{flex:1;display:flex;flex-direction:column;align-items:center;gap:8px;height:100%;justify-content:flex-end}
.bar-chart .bar .fill{width:100%;background:var(--gradient);border-radius:6px 6px 0 0;min-height:4px;transition:height .6s ease}
.bar-chart .bar .lbl{font-size:.7rem;color:var(--muted)}
.bar-chart .bar .val{font-size:.68rem;color:var(--primary-2);font-weight:700}
.empty{text-align:center;padding:40px;color:var(--muted)}
.empty i{font-size:2.5rem;margin-bottom:12px;opacity:.4}
.flex{display:flex}.items-center{align-items:center}.justify-between{justify-content:space-between}.gap-2{gap:8px}.gap-3{gap:16px}
.mt-2{margin-top:16px}.mt-3{margin-top:24px}.mb-2{margin-bottom:16px}.mb-3{margin-bottom:24px}
.text-muted{color:var(--muted)}.text-success{color:var(--success)}.text-error{color:var(--error)}
.text-center{text-align:center}.w-full{width:100%}
.grid-2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media(max-width:700px){.grid-2{grid-template-columns:1fr}}
AGH_ADMIN_EOF
log "CSS files written"

# ============================================================
# 7. JS FILES
# ============================================================
step "Writing JavaScript files"
cat > public/js/main.js <<'AGH_MAIN_EOF'
(function(){'use strict';
const nav=document.querySelector('.navbar');if(nav)window.addEventListener('scroll',()=>nav.classList.toggle('scrolled',window.scrollY>20));
const toggle=document.querySelector('.nav-toggle'),menu=document.querySelector('.nav-menu');
if(toggle&&menu)toggle.addEventListener('click',()=>menu.classList.toggle('open'));
document.querySelectorAll('.faq-q').forEach(q=>q.addEventListener('click',()=>q.closest('.faq-item').classList.toggle('open')));
const obs=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('visible');obs.unobserve(e.target);}}),{threshold:.1});
document.querySelectorAll('.reveal').forEach(el=>obs.observe(el));
const pe=document.querySelector('.bg-particles');
if(pe&&!document.body.classList.contains('no-animations')){for(let i=0;i<20;i++){const p=document.createElement('div');p.className='particle';p.style.left=Math.random()*100+'%';p.style.animationDelay=Math.random()*15+'s';p.style.animationDuration=(10+Math.random()*15)+'s';p.style.opacity=.15+Math.random()*.4;pe.appendChild(p);}}
document.querySelectorAll('[data-count]').forEach(el=>{const t=parseFloat(el.dataset.count),s=el.dataset.suffix||'';let c=0,step=t/60;const ti=setInterval(()=>{c+=step;if(c>=t){c=t;clearInterval(ti);}el.textContent=(Number.isInteger(t)?Math.floor(c):c.toFixed(1))+s;},20);});
document.querySelectorAll('.flash').forEach(el=>setTimeout(()=>{el.style.opacity='0';el.style.transform='translateX(400px)';setTimeout(()=>el.remove(),300);},5000));
document.querySelectorAll('[data-confirm]').forEach(el=>el.addEventListener('click',e=>{if(!confirm(el.dataset.confirm||'Are you sure?'))e.preventDefault();}));
document.querySelectorAll('[data-copy]').forEach(el=>el.addEventListener('click',()=>{navigator.clipboard.writeText(el.dataset.copy);const o=el.textContent;el.textContent='Copied!';setTimeout(()=>el.textContent=o,1200);}));
})();
AGH_MAIN_EOF

cat > public/js/admin.js <<'AGH_ADMINJS_EOF'
(function(){'use strict';
const t=document.querySelector('.menu-toggle'),sb=document.querySelector('.sidebar'),ov=document.querySelector('.sidebar-overlay');
if(t&&sb)t.addEventListener('click',()=>{sb.classList.toggle('open');if(ov)ov.classList.toggle('open');});
if(ov)ov.addEventListener('click',()=>{sb.classList.remove('open');ov.classList.remove('open');});
document.querySelectorAll('.flash').forEach(el=>setTimeout(()=>{el.style.opacity='0';setTimeout(()=>el.remove(),300);},4000));
document.querySelectorAll('[data-confirm]').forEach(el=>el.addEventListener('click',e=>{if(!confirm(el.dataset.confirm||'Are you sure?'))e.preventDefault();}));
document.querySelectorAll('[data-modal]').forEach(b=>b.addEventListener('click',()=>{const m=document.getElementById(b.dataset.modal);if(m)m.classList.add('open');}));
document.querySelectorAll('.modal-overlay').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');}));
document.querySelectorAll('[data-close-modal]').forEach(b=>b.addEventListener('click',()=>b.closest('.modal-overlay').classList.remove('open')));
document.querySelectorAll('.bar-chart .fill').forEach(el=>{const h=el.dataset.height||'0';el.style.height='0';setTimeout(()=>{el.style.height=h+'%';},100);});
})();
AGH_ADMINJS_EOF
log "JS files written"

# ============================================================
# 8. PARTIALS
# ============================================================
step "Writing EJS partials"
cat > views/partials/header.ejs <<'AGH_HEADER_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><%= typeof title !== 'undefined' ? title : settings.site_name %></title>
  <meta name="description" content="<%= settings.seo_description %>">
  <meta name="keywords" content="<%= settings.seo_keywords %>">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
  <link rel="stylesheet" href="/css/style.css">
  <% if (theme && theme.vars) { %><style>:root {<% for (const k in theme.vars) { %><%= k %>: <%= theme.vars[k] %>;<% } %>}</style><% } %>
</head>
<body class="<%= settings.animations_enabled ? '' : 'no-animations' %>">
  <div class="bg-particles"></div>
  <nav class="navbar">
    <div class="nav-container">
      <a href="/" class="nav-logo"><div class="logo-icon">AG</div><span><%= settings.site_name %></span></a>
      <ul class="nav-menu">
        <li><a href="/" class="<%= currentPath === '/' ? 'active' : '' %>">Home</a></li>
        <li><a href="/categories" class="<%= currentPath === '/categories' ? 'active' : '' %>">Hosting</a></li>
        <li><a href="/products" class="<%= currentPath === '/products' ? 'active' : '' %>">Plans</a></li>
        <li><a href="/faq" class="<%= currentPath === '/faq' ? 'active' : '' %>">FAQ</a></li>
        <li><a href="/contact" class="<%= currentPath === '/contact' ? 'active' : '' %>">Contact</a></li>
      </ul>
      <div class="nav-actions">
        <a href="/cart" class="btn btn-ghost cart-badge"><i class="fas fa-shopping-cart"></i><span>Cart</span><% if (cartCount > 0) { %><span class="badge"><%= cartCount %></span><% } %></a>
        <% if (currentUser) { %><a href="/dashboard" class="btn btn-primary"><i class="fas fa-user"></i><span><%= currentUser.name.split(' ')[0] %></span></a>
        <% } else { %><a href="/auth/login" class="btn btn-outline"><i class="fas fa-sign-in-alt"></i><span>Login</span></a><a href="/auth/register" class="btn btn-primary"><span>Sign Up</span></a><% } %>
        <button class="nav-toggle"><i class="fas fa-bars"></i></button>
      </div>
    </div>
  </nav>
  <% if ((flashSuccess && flashSuccess.length) || (flashError && flashError.length) || (flashInfo && flashInfo.length)) { %>
    <div class="flash-container">
      <% (flashSuccess||[]).forEach(m => { %><div class="flash success"><%= m %></div><% }) %>
      <% (flashError||[]).forEach(m => { %><div class="flash error"><%= m %></div><% }) %>
      <% (flashInfo||[]).forEach(m => { %><div class="flash info"><%= m %></div><% }) %>
    </div>
  <% } %>
AGH_HEADER_EOF

cat > views/partials/footer.ejs <<'AGH_FOOTER_EOF'
  <footer class="footer"><div class="footer-inner">
    <div class="footer-grid">
      <div>
        <div class="footer-brand"><div class="logo-icon" style="width:36px;height:36px;background:var(--gradient);border-radius:9px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;">AG</div><%= settings.site_name %></div>
        <p><%= settings.site_description %></p>
        <% if (settings.discord_invite) { %><a href="<%= settings.discord_invite %>" target="_blank" rel="noopener" class="discord-btn"><i class="fab fa-discord"></i> Join Discord</a><% } %>
      </div>
      <div><h4>Hosting</h4><ul><li><a href="/category/game-hosting">Game Hosting</a></li><li><a href="/category/vps-hosting">VPS Hosting</a></li><li><a href="/category/minecraft-java">Minecraft Hosting</a></li><li><a href="/category/discord-bot-hosting">Bot Hosting</a></li><li><a href="/category/windows-rdp">Windows RDP</a></li></ul></div>
      <div><h4>Company</h4><ul><li><a href="/about">About Us</a></li><li><a href="/contact">Contact</a></li><li><a href="/faq">FAQ</a></li><li><a href="/documentation">Documentation</a></li></ul></div>
      <div><h4>Legal</h4><ul><li><a href="/terms">Terms of Service</a></li><li><a href="/privacy">Privacy Policy</a></li><li><a href="/auth/login">Client Area</a></li></ul></div>
    </div>
    <div class="footer-bottom">© <%= new Date().getFullYear() %> <%= settings.site_name %>. All rights reserved.</div>
  </div></footer>
  <script src="/js/main.js"></script>
</body></html>
AGH_FOOTER_EOF

cat > views/partials/admin-header.ejs <<'AGH_ADMHEAD_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><%= typeof title !== 'undefined' ? title + ' · Admin' : 'Admin' %></title>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
  <link rel="stylesheet" href="/css/admin.css">
</head>
<body>
  <div class="admin-layout">
    <div class="sidebar-overlay"></div>
    <aside class="sidebar">
      <div class="sidebar-brand"><div class="logo-icon">AG</div> Admin Panel</div>
      <div class="sidebar-section">Main</div>
      <nav class="sidebar-nav">
        <a href="/admin" class="<%= currentPath === '/admin' ? 'active' : '' %>"><i class="fas fa-tachometer-alt"></i> Dashboard</a>
        <a href="/admin/orders" class="<%= currentPath.startsWith('/admin/orders') ? 'active' : '' %>"><i class="fas fa-shopping-bag"></i> Orders</a>
        <a href="/admin/customers" class="<%= currentPath.startsWith('/admin/customers') ? 'active' : '' %>"><i class="fas fa-users"></i> Customers</a>
        <a href="/admin/tickets" class="<%= currentPath.startsWith('/admin/tickets') ? 'active' : '' %>"><i class="fas fa-headset"></i> Tickets</a>
        <a href="/admin/payments" class="<%= currentPath === '/admin/payments' ? 'active' : '' %>"><i class="fas fa-credit-card"></i> Payments</a>
        <a href="/admin/invoices" class="<%= currentPath === '/admin/invoices' ? 'active' : '' %>"><i class="fas fa-file-invoice"></i> Invoices</a>
      </nav>
      <div class="sidebar-section">Store</div>
      <nav class="sidebar-nav">
        <a href="/admin/products" class="<%= currentPath.startsWith('/admin/products') ? 'active' : '' %>"><i class="fas fa-server"></i> Products</a>
        <a href="/admin/categories" class="<%= currentPath === '/admin/categories' ? 'active' : '' %>"><i class="fas fa-folder"></i> Categories</a>
        <a href="/admin/coupons" class="<%= currentPath === '/admin/coupons' ? 'active' : '' %>"><i class="fas fa-tag"></i> Coupons</a>
      </nav>
      <div class="sidebar-section">Content</div>
      <nav class="sidebar-nav">
        <a href="/admin/themes" class="<%= currentPath === '/admin/themes' ? 'active' : '' %>"><i class="fas fa-palette"></i> Themes</a>
        <a href="/admin/animations" class="<%= currentPath === '/admin/animations' ? 'active' : '' %>"><i class="fas fa-magic"></i> Animations</a>
        <a href="/admin/announcements" class="<%= currentPath === '/admin/announcements' ? 'active' : '' %>"><i class="fas fa-bullhorn"></i> Announcements</a>
        <a href="/admin/notifications" class="<%= currentPath === '/admin/notifications' ? 'active' : '' %>"><i class="fas fa-bell"></i> Notifications</a>
        <a href="/admin/contact-messages" class="<%= currentPath === '/admin/contact-messages' ? 'active' : '' %>"><i class="fas fa-envelope"></i> Messages</a>
      </nav>
      <div class="sidebar-section">Settings</div>
      <nav class="sidebar-nav">
        <a href="/admin/website-settings" class="<%= currentPath === '/admin/website-settings' ? 'active' : '' %>"><i class="fas fa-cog"></i> Website</a>
        <a href="/admin/seo-settings" class="<%= currentPath === '/admin/seo-settings' ? 'active' : '' %>"><i class="fas fa-search"></i> SEO</a>
        <a href="/admin/payment-settings" class="<%= currentPath === '/admin/payment-settings' ? 'active' : '' %>"><i class="fas fa-credit-card"></i> Payments</a>
        <a href="/admin/email-settings" class="<%= currentPath === '/admin/email-settings' ? 'active' : '' %>"><i class="fas fa-envelope-open"></i> Email</a>
        <a href="/admin/security-settings" class="<%= currentPath === '/admin/security-settings' ? 'active' : '' %>"><i class="fas fa-shield-alt"></i> Security</a>
        <a href="/admin/navigation" class="<%= currentPath === '/admin/navigation' ? 'active' : '' %>"><i class="fas fa-bars"></i> Navigation</a>
        <a href="/admin/staff" class="<%= currentPath === '/admin/staff' ? 'active' : '' %>"><i class="fas fa-user-tie"></i> Staff</a>
        <a href="/admin/activity-logs" class="<%= currentPath === '/admin/activity-logs' ? 'active' : '' %>"><i class="fas fa-history"></i> Activity Logs</a>
        <a href="/admin/maintenance" class="<%= currentPath === '/admin/maintenance' ? 'active' : '' %>"><i class="fas fa-tools"></i> Maintenance</a>
      </nav>
    </aside>
    <main class="admin-main">
      <header class="admin-header">
        <div style="display:flex;align-items:center;gap:12px;">
          <button class="menu-toggle"><i class="fas fa-bars"></i></button>
          <div class="header-title"><h1><%= typeof title !== 'undefined' ? title : 'Admin' %></h1><div class="crumb">AG Tech Hosting</div></div>
        </div>
        <div class="header-actions">
          <a href="/" target="_blank" class="btn btn-outline btn-sm"><i class="fas fa-external-link-alt"></i> View Site</a>
          <div class="user-chip"><div class="av"><%= adminUser ? adminUser.name.charAt(0).toUpperCase() : 'A' %></div><span><%= adminUser ? adminUser.name : 'Admin' %></span></div>
          <form method="POST" action="/auth/logout" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-outline btn-sm"><i class="fas fa-sign-out-alt"></i></button></form>
        </div>
      </header>
      <% if ((flashSuccess && flashSuccess.length) || (flashError && flashError.length) || (flashInfo && flashInfo.length)) { %>
      <div class="flash-container">
        <% (flashSuccess||[]).forEach(m => { %><div class="flash success"><%= m %></div><% }) %>
        <% (flashError||[]).forEach(m => { %><div class="flash error"><%= m %></div><% }) %>
        <% (flashInfo||[]).forEach(m => { %><div class="flash info"><%= m %></div><% }) %>
      </div>
      <% } %>
      <div class="admin-content">
AGH_ADMHEAD_EOF

cat > views/partials/admin-sidebar.ejs <<'AGH_ADMSIDE_EOF'
<!-- Sidebar is embedded in admin-header for grid layout -->
AGH_ADMSIDE_EOF

cat > views/partials/admin-footer.ejs <<'AGH_ADMFOOT_EOF'
      </div>
    </main>
  </div>
  <script src="/js/admin.js"></script>
</body></html>
AGH_ADMFOOT_EOF
log "Partials written"

# ============================================================
# 9. CUSTOMER VIEWS
# ============================================================
step "Writing customer EJS views"

cat > views/customer/index.ejs <<'AGH_C_INDEX_EOF'
<%- include('../partials/header') %>
<section class="hero"><div class="hero-content">
  <div class="hero-badge"><span class="dot"></span> 99.9% Uptime Guarantee · DDoS Protected</div>
  <h1>Premium Hosting<br><span class="gradient-text">Built for Performance</span></h1>
  <p><%= settings.site_description %></p>
  <div class="hero-actions"><a href="/products" class="btn btn-primary btn-lg"><i class="fas fa-rocket"></i> Explore Plans</a><a href="/categories" class="btn btn-outline btn-lg"><i class="fas fa-server"></i> View Categories</a></div>
  <div class="hero-stats">
    <div class="hero-stat"><div class="num" data-count="99.9" data-suffix="%">0%</div><div class="label">Uptime SLA</div></div>
    <div class="hero-stat"><div class="num" data-count="15000" data-suffix="+">0</div><div class="label">Servers Deployed</div></div>
    <div class="hero-stat"><div class="num" data-count="24" data-suffix="/7">0</div><div class="label">Support</div></div>
    <div class="hero-stat"><div class="num" data-count="12" data-suffix="+">0</div><div class="label">Locations</div></div>
  </div>
</div></section>
<% if (announcements && announcements.length) { %><section class="section" style="padding-top:20px;padding-bottom:20px;"><% announcements.forEach(a => { %><div class="announcement-banner"><i class="fas fa-bullhorn"></i><div><strong><%= a.title %>:</strong> <%= a.message %></div></div><% }) %></section><% } %>
<section class="section"><div class="section-header"><span class="section-tag">Hosting Solutions</span><h2>Choose Your Category</h2><p>From game servers to enterprise VPS — find the perfect plan.</p></div>
<div class="grid grid-4"><% categories.slice(0,8).forEach(c => { %><a href="/category/<%= c.slug %>" class="category-card reveal"><div class="cat-icon"><i class="fas <%= c.icon || 'fa-server' %>"></i></div><h3><%= c.name %></h3><p><%= c.description || 'High performance hosting' %></p></a><% }) %></div>
<% if (categories.length > 8) { %><div class="text-center mt-4"><a href="/categories" class="btn btn-outline">View All Categories</a></div><% } %></section>
<% if (featured && featured.length) { %><section class="section"><div class="section-header"><span class="section-tag">Featured</span><h2>Featured Hosting Plans</h2><p>Handpicked plans trusted by thousands.</p></div>
<div class="grid grid-3"><% featured.forEach(p => { %><div class="product-card reveal"><% if (p.featured) { %><span class="ribbon">Featured</span><% } %><% if (p.image) { %><img src="<%= p.image %>" alt="<%= p.name %>" class="product-img"><% } else { %><div class="product-img-placeholder"><i class="fas fa-server"></i></div><% } %>
<div class="product-body"><div class="product-cat"><%= p.category_name %></div><h3><%= p.name %></h3><p class="desc"><%= (p.description || '').slice(0,90) %></p>
<div class="product-specs"><% if (p.cpu) { %><div class="spec"><i class="fas fa-microchip"></i><%= p.cpu %></div><% } %><% if (p.ram) { %><div class="spec"><i class="fas fa-memory"></i><%= p.ram %></div><% } %><% if (p.storage) { %><div class="spec"><i class="fas fa-hdd"></i><%= p.storage %></div><% } %><% if (p.bandwidth) { %><div class="spec"><i class="fas fa-tachometer-alt"></i><%= p.bandwidth %></div><% } %></div>
<div class="product-price"><span class="amount">$<%= p.price_monthly.toFixed(2) %></span><span class="period">/mo</span></div>
<a href="/product/<%= p.slug %>" class="btn btn-primary btn-block">View Plan</a></div></div><% }) %></div></section><% } %>
<% if (popular && popular.length) { %><section class="section"><div class="section-header"><span class="section-tag">Popular</span><h2>Most Popular Products</h2></div>
<div class="grid grid-3"><% popular.forEach(p => { %><div class="product-card reveal"><span class="ribbon popular">Popular</span><% if (p.image) { %><img src="<%= p.image %>" alt="<%= p.name %>" class="product-img"><% } else { %><div class="product-img-placeholder"><i class="fas fa-fire"></i></div><% } %>
<div class="product-body"><div class="product-cat"><%= p.category_name %></div><h3><%= p.name %></h3><p class="desc"><%= (p.description || '').slice(0,90) %></p>
<div class="product-price"><span class="amount">$<%= p.price_monthly.toFixed(2) %></span><span class="period">/mo</span></div>
<a href="/product/<%= p.slug %>" class="btn btn-primary btn-block">Order Now</a></div></div><% }) %></div></section><% } %>
<section class="section"><div class="section-header"><span class="section-tag">Why Us</span><h2>Why Choose <%= settings.site_name %>?</h2><p>Premium infrastructure, unbeatable performance.</p></div>
<div class="grid grid-2">
  <div class="feature reveal"><div class="icon"><i class="fas fa-bolt"></i></div><div><h3>Lightning Fast</h3><p>NVMe SSD storage, DDR5 RAM, 1 Gbps+ network on every plan.</p></div></div>
  <div class="feature reveal"><div class="icon"><i class="fas fa-shield-alt"></i></div><div><h3>DDoS Protection</h3><p>Enterprise-grade 2 Tbps DDoS mitigation included.</p></div></div>
  <div class="feature reveal"><div class="icon"><i class="fas fa-clock"></i></div><div><h3>99.9% Uptime</h3><p>Redundant infrastructure guarantees availability.</p></div></div>
  <div class="feature reveal"><div class="icon"><i class="fas fa-headset"></i></div><div><h3>24/7 Support</h3><p>Real humans ready via ticket, chat, and Discord.</p></div></div>
  <div class="feature reveal"><div class="icon"><i class="fas fa-cogs"></i></div><div><h3>Instant Setup</h3><p>Deployed automatically in seconds after payment.</p></div></div>
  <div class="feature reveal"><div class="icon"><i class="fas fa-globe"></i></div><div><h3>Global Network</h3><p>12+ locations across North America, Europe, Asia.</p></div></div>
</div></section>
<section class="section"><div class="section-header"><span class="section-tag">Network</span><h2>Server Locations</h2></div>
<div class="grid grid-4">
  <div class="location reveal"><div class="flag">🇮🇳</div><h4>India</h4><p>Mumbai · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇺🇸</div><h4>USA</h4><p>New York · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇬🇧</div><h4>UK</h4><p>London · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇩🇪</div><h4>Germany</h4><p>Frankfurt · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇸🇬</div><h4>Singapore</h4><p>Singapore · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇦🇺</div><h4>Australia</h4><p>Sydney · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇧🇷</div><h4>Brazil</h4><p>São Paulo · 1 Gbps</p></div>
  <div class="location reveal"><div class="flag">🇯🇵</div><h4>Japan</h4><p>Tokyo · 1 Gbps</p></div>
</div></section>
<section class="section"><div class="section-header"><span class="section-tag">Testimonials</span><h2>Loved by Thousands</h2></div>
<div class="grid grid-3">
  <div class="testimonial reveal"><div class="stars">★★★★★</div><p class="quote">"Best hosting I've used. Setup was instant and support is incredible."</p><div class="author"><div class="av">R</div><div><strong>Rahul Kumar</strong><span>Minecraft Server Owner</span></div></div></div>
  <div class="testimonial reveal"><div class="stars">★★★★★</div><p class="quote">"Migrated from another provider and never looked back."</p><div class="author"><div class="av">J</div><div><strong>James Wilson</strong><span>Gaming Community Lead</span></div></div></div>
  <div class="testimonial reveal"><div class="stars">★★★★★</div><p class="quote">"Our Discord bot runs flawlessly for 6 months."</p><div class="author"><div class="av">A</div><div><strong>Aisha Patel</strong><span>Discord Developer</span></div></div></div>
</div></section>
<section class="section" style="text-align:center;"><h2 style="font-size:2.2rem;margin-bottom:12px;">Ready to Get Started?</h2><p class="text-muted" style="margin-bottom:28px;">Deploy your server in under 60 seconds.</p><a href="/products" class="btn btn-primary btn-lg"><i class="fas fa-rocket"></i> Browse All Plans</a></section>
<%- include('../partials/footer') %>
AGH_C_INDEX_EOF

cat > views/customer/categories.ejs <<'AGH_C_CATS_EOF'
<%- include('../partials/header') %>
<section class="section"><div class="section-header"><span class="section-tag">All Categories</span><h1 style="font-size:2.4rem;font-weight:800;margin-bottom:12px;">Hosting Categories</h1><p>Pick a category to explore all plans.</p></div>
<div class="grid grid-4"><% categories.forEach(c => { %><a href="/category/<%= c.slug %>" class="category-card reveal"><div class="cat-icon"><i class="fas <%= c.icon || 'fa-server' %>"></i></div><h3><%= c.name %></h3><p><%= c.description || '' %></p></a><% }) %></div></section>
<%- include('../partials/footer') %>
AGH_C_CATS_EOF

cat > views/customer/products.ejs <<'AGH_C_PRODS_EOF'
<%- include('../partials/header') %>
<section class="section"><div class="section-header"><span class="section-tag"><%= category ? category.name : 'All Products' %></span><h1 style="font-size:2.2rem;font-weight:800;margin-bottom:12px;"><%= category ? category.name : 'Browse Plans' %></h1><p><%= category ? category.description : 'All available hosting plans.' %></p></div>
<form method="GET" action="/products" class="mb-4" style="max-width:600px;margin:0 auto 40px;display:flex;gap:8px;"><input type="text" name="q" class="form-input" placeholder="Search plans..." value="<%= typeof q !== 'undefined' ? q : '' %>"><button class="btn btn-primary"><i class="fas fa-search"></i></button></form>
<% if (!products.length) { %><div class="empty-state"><i class="fas fa-box-open"></i><h3>No products found</h3><p>Try a different search.</p></div><% } else { %>
<div class="grid grid-3"><% products.forEach(p => { %><div class="product-card reveal"><% if (p.featured) { %><span class="ribbon">Featured</span><% } else if (p.popular) { %><span class="ribbon popular">Popular</span><% } %><% if (p.image) { %><img src="<%= p.image %>" alt="<%= p.name %>" class="product-img"><% } else { %><div class="product-img-placeholder"><i class="fas fa-server"></i></div><% } %>
<div class="product-body"><div class="product-cat"><%= p.category_name %></div><h3><%= p.name %></h3><p class="desc"><%= (p.description || '').slice(0,100) %></p>
<div class="product-specs"><% if (p.cpu) { %><div class="spec"><i class="fas fa-microchip"></i><%= p.cpu %></div><% } %><% if (p.ram) { %><div class="spec"><i class="fas fa-memory"></i><%= p.ram %></div><% } %><% if (p.storage) { %><div class="spec"><i class="fas fa-hdd"></i><%= p.storage %></div><% } %><% if (p.bandwidth) { %><div class="spec"><i class="fas fa-tachometer-alt"></i><%= p.bandwidth %></div><% } %></div>
<div class="product-price"><span class="amount">$<%= p.price_monthly.toFixed(2) %></span><span class="period">/mo</span></div>
<a href="/product/<%= p.slug %>" class="btn btn-primary btn-block">View Plan</a></div></div><% }) %></div>
<% } %></section>
<%- include('../partials/footer') %>
AGH_C_PRODS_EOF

cat > views/customer/product-details.ejs <<'AGH_C_PD_EOF'
<%- include('../partials/header') %>
<div class="product-detail-hero">
<div><% if (product.image) { %><img src="<%= product.image %>" alt="<%= product.name %>" style="border-radius:var(--radius);width:100%;"><% } else { %><div class="product-img-placeholder" style="border-radius:var(--radius);height:320px;font-size:5rem;"><i class="fas fa-server"></i></div><% } %></div>
<div>
<div class="product-cat" style="margin-bottom:8px;"><%= product.category_name %></div>
<h1 style="font-size:2.2rem;font-weight:800;margin-bottom:12px;"><%= product.name %></h1>
<p class="text-muted" style="margin-bottom:20px;"><%= product.description %></p>
<div class="product-price" style="margin-bottom:24px;"><span class="amount" style="font-size:2.6rem;">$<%= product.price_monthly.toFixed(2) %></span><span class="period">/month</span></div>
<div class="product-spec-grid">
<% if (product.cpu) { %><div class="spec-item"><div class="label">CPU</div><div class="value"><%= product.cpu %></div></div><% } %>
<% if (product.ram) { %><div class="spec-item"><div class="label">RAM</div><div class="value"><%= product.ram %></div></div><% } %>
<% if (product.storage) { %><div class="spec-item"><div class="label">Storage</div><div class="value"><%= product.storage %></div></div><% } %>
<% if (product.bandwidth) { %><div class="spec-item"><div class="label">Bandwidth</div><div class="value"><%= product.bandwidth %></div></div><% } %>
<% if (product.network) { %><div class="spec-item"><div class="label">Network</div><div class="value"><%= product.network %></div></div><% } %>
<% if (product.location) { %><div class="spec-item"><div class="label">Location</div><div class="value"><%= product.location %></div></div><% } %>
<% if (product.os) { %><div class="spec-item"><div class="label">OS</div><div class="value"><%= product.os %></div></div><% } %>
</div>
<% if (features && features.length) { %><div style="margin-bottom:24px;"><h3 style="font-size:1rem;margin-bottom:12px;">Features Included:</h3><ul style="list-style:none;display:flex;flex-wrap:wrap;gap:8px;"><% features.forEach(f => { %><li class="badge badge-primary"><%= f %></li><% }) %></ul></div><% } %>
<form method="POST" action="/cart/add">
<input type="hidden" name="_csrf" value="<%= csrfToken %>">
<input type="hidden" name="product_id" value="<%= product.id %>">
<div class="form-group"><label class="form-label">Billing Cycle</label><select name="billing_cycle" class="form-select" style="max-width:260px;">
<option value="monthly">Monthly — $<%= product.price_monthly.toFixed(2) %></option>
<% if (product.price_quarterly) { %><option value="quarterly">Quarterly — $<%= product.price_quarterly.toFixed(2) %></option><% } %>
<% if (product.price_yearly) { %><option value="yearly">Yearly — $<%= product.price_yearly.toFixed(2) %></option><% } %>
</select></div>
<div class="form-group"><label class="form-label">Quantity</label><input type="number" name="quantity" class="form-input" value="1" min="1" max="10" style="max-width:120px;"></div>
<button class="btn btn-primary btn-lg"><i class="fas fa-shopping-cart"></i> Add to Cart</button>
</form>
</div></div>
<% if (related && related.length) { %><section class="section"><div class="section-header"><span class="section-tag">Related</span><h2>Similar Plans</h2></div>
<div class="grid grid-3"><% related.forEach(p => { %><div class="product-card"><div class="product-img-placeholder"><i class="fas fa-server"></i></div><div class="product-body"><h3><%= p.name %></h3><div class="product-price"><span class="amount">$<%= p.price_monthly.toFixed(2) %></span><span class="period">/mo</span></div><a href="/product/<%= p.slug %>" class="btn btn-primary btn-block">View</a></div></div><% }) %></div></section><% } %>
<%- include('../partials/footer') %>
AGH_C_PD_EOF

cat > views/customer/faq.ejs <<'AGH_C_FAQ_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><span class="section-tag">FAQ</span><h1 style="font-size:2.4rem;font-weight:800;margin-bottom:12px;">Frequently Asked Questions</h1></div>
<% const faqs = [['How fast is my server deployed?','Almost all plans are deployed automatically within 30-60 seconds after payment.'],['Do you offer DDoS protection?','Yes, all servers include free enterprise-grade DDoS protection.'],['What payment methods do you accept?','UPI, bank transfer, Razorpay, Stripe, PayPal, and more.'],['Can I upgrade my plan later?','Yes, from your dashboard — prorated billing applies.'],['Do you offer refunds?','24-hour money-back guarantee for new customers.'],['Is there a setup fee?','No setup fees on any plan.'],['Which locations are available?','India, USA, UK, Germany, Singapore, Australia, Brazil, Japan.'],['How can I get support?','24/7 via tickets, Discord community, and email.']]; %>
<% faqs.forEach(([q,a]) => { %><div class="faq-item"><div class="faq-q"><span><%= q %></span><i class="fas fa-chevron-down"></i></div><div class="faq-a"><%= a %></div></div><% }) %>
</section>
<%- include('../partials/footer') %>
AGH_C_FAQ_EOF

cat > views/customer/about.ejs <<'AGH_C_ABOUT_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><span class="section-tag">About</span><h1 style="font-size:2.4rem;font-weight:800;margin-bottom:12px;">About <%= settings.site_name %></h1></div>
<div class="card"><p style="margin-bottom:16px;"><%= settings.site_name %> is a premium hosting provider built by gamers, for gamers. High-performance infrastructure for game servers, VPS, RDP, bots, and web apps.</p>
<p style="margin-bottom:16px;">Founded in 2023, serving thousands of customers across 12+ global locations with 99.9% uptime SLA.</p>
<p>Our mission: enterprise-grade hosting at prices normal humans can afford.</p></div></section>
<%- include('../partials/footer') %>
AGH_C_ABOUT_EOF

cat > views/customer/terms.ejs <<'AGH_C_TERMS_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><h1 style="font-size:2.2rem;font-weight:800;">Terms of Service</h1></div>
<div class="card"><p style="margin-bottom:16px;">By using <%= settings.site_name %>, you agree to these terms. Do not use our services for illegal activities, spam, DDoS attacks, or content that violates laws.</p>
<p style="margin-bottom:16px;"><strong>Payments:</strong> Due upfront. Unpaid accounts will be suspended.</p>
<p style="margin-bottom:16px;"><strong>Refunds:</strong> 24-hour money-back for new customers.</p>
<p><strong>Termination:</strong> We may terminate accounts that violate these terms.</p></div></section>
<%- include('../partials/footer') %>
AGH_C_TERMS_EOF

cat > views/customer/privacy.ejs <<'AGH_C_PRIV_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><h1 style="font-size:2.2rem;font-weight:800;">Privacy Policy</h1></div>
<div class="card"><p style="margin-bottom:16px;">We collect minimum information: name, email, payment details.</p>
<p style="margin-bottom:16px;">We never sell data. Payment details processed by PCI-compliant processors.</p>
<p>For data deletion, contact <%= settings.contact_email %>.</p></div></section>
<%- include('../partials/footer') %>
AGH_C_PRIV_EOF

cat > views/customer/documentation.ejs <<'AGH_C_DOCS_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><span class="section-tag">Docs</span><h1 style="font-size:2.2rem;font-weight:800;">Documentation</h1></div>
<div class="card"><h3 style="margin-bottom:12px;">Getting Started</h3>
<ol style="padding-left:20px;line-height:2;color:var(--muted);"><li>Create account at <a href="/auth/register">/auth/register</a></li><li>Choose plan from <a href="/products">Products</a></li><li>Add to cart and checkout</li><li>Complete payment</li><li>Access services from <a href="/services">My Services</a></li></ol>
<h3 style="margin:20px 0 12px;">Managing Your Server</h3>
<p class="text-muted">Once deployed, you'll receive panel credentials via email.</p>
<h3 style="margin:20px 0 12px;">Need Help?</h3>
<p class="text-muted">Open a ticket from <a href="/tickets">Support</a>.</p></div></section>
<%- include('../partials/footer') %>
AGH_C_DOCS_EOF

cat > views/customer/contact.ejs <<'AGH_C_CONTACT_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:900px;"><div class="section-header"><span class="section-tag">Contact</span><h1 style="font-size:2.2rem;font-weight:800;margin-bottom:12px;">Get in Touch</h1><p>We respond within 1-2 hours.</p></div>
<div class="grid grid-2">
<div class="card"><h3 style="margin-bottom:14px;">Send us a message</h3>
<form method="POST" action="/contact"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" required></div>
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required></div>
<div class="form-group"><label class="form-label">Subject</label><input type="text" name="subject" class="form-input"></div>
<div class="form-group"><label class="form-label">Message</label><textarea name="message" class="form-textarea" required></textarea></div>
<button class="btn btn-primary btn-block"><i class="fas fa-paper-plane"></i> Send Message</button></form></div>
<div class="card"><h3 style="margin-bottom:14px;">Other ways</h3>
<p style="margin-bottom:12px;"><i class="fas fa-envelope" style="color:var(--primary);width:20px;"></i> <%= settings.contact_email %></p>
<p style="margin-bottom:12px;"><i class="fas fa-phone" style="color:var(--primary);width:20px;"></i> <%= settings.contact_phone %></p>
<% if (settings.discord_invite) { %><a href="<%= settings.discord_invite %>" class="discord-btn"><i class="fab fa-discord"></i> Discord Server</a><% } %>
<p class="text-muted mt-3" style="font-size:0.85rem;">For urgent issues, open a support ticket.</p></div>
</div></section>
<%- include('../partials/footer') %>
AGH_C_CONTACT_EOF

cat > views/customer/404.ejs <<'AGH_C_404_EOF'
<%- include('../partials/header') %>
<section class="section" style="text-align:center;padding-top:120px;">
<h1 style="font-size:6rem;font-weight:900;background:var(--gradient);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;">404</h1>
<h2 style="margin-bottom:12px;">Page Not Found</h2>
<p class="text-muted" style="margin-bottom:24px;">The page you're looking for doesn't exist.</p>
<a href="/" class="btn btn-primary"><i class="fas fa-home"></i> Back to Home</a>
</section>
<%- include('../partials/footer') %>
AGH_C_404_EOF

cat > views/customer/maintenance-mode.ejs <<'AGH_C_MAINT_EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Maintenance</title><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css"><link rel="stylesheet" href="/css/style.css"></head>
<body><div style="min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;"><div>
<i class="fas fa-tools" style="font-size:4rem;color:var(--primary);margin-bottom:20px;"></i>
<h1 style="font-size:2rem;margin-bottom:12px;">We'll be right back</h1>
<p class="text-muted">We're performing scheduled maintenance.</p>
</div></div></body></html>
AGH_C_MAINT_EOF
log "Public customer views written"

# ============================================================
# 10. AUTH + DASHBOARD + COMMERCE
# ============================================================
step "Writing auth, dashboard, commerce views"

cat > views/customer/login.ejs <<'AGH_C_LOGIN_EOF'
<%- include('../partials/header') %>
<div class="auth-wrap"><div class="auth-card">
<div class="logo"><div style="width:52px;height:52px;background:var(--gradient);border-radius:12px;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:900;font-size:1.1rem;box-shadow:0 0 30px rgba(139,92,246,0.5);">AG</div></div>
<h1>Welcome Back</h1><p class="subtitle">Log in to manage your hosting</p>
<form method="POST" action="/auth/login"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><input type="hidden" name="next" value="<%= next %>">
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required autofocus></div>
<div class="form-group"><label class="form-label">Password</label><input type="password" name="password" class="form-input" required></div>
<button class="btn btn-primary btn-block">Log In</button></form>
<div class="auth-footer"><a href="/auth/forgot-password">Forgot password?</a> · <a href="/auth/register">Create account</a></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_LOGIN_EOF

cat > views/customer/register.ejs <<'AGH_C_REG_EOF'
<%- include('../partials/header') %>
<div class="auth-wrap"><div class="auth-card">
<h1>Create Account</h1><p class="subtitle">Join thousands of happy customers</p>
<form method="POST" action="/auth/register"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Full Name</label><input type="text" name="name" class="form-input" required minlength="2"></div>
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required></div>
<div class="form-group"><label class="form-label">Password</label><input type="password" name="password" class="form-input" required minlength="8"><div class="form-hint">At least 8 characters</div></div>
<button class="btn btn-primary btn-block">Sign Up</button></form>
<div class="auth-footer">Already have an account? <a href="/auth/login">Log in</a></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_REG_EOF

cat > views/customer/forgot-password.ejs <<'AGH_C_FORGOT_EOF'
<%- include('../partials/header') %>
<div class="auth-wrap"><div class="auth-card">
<h1>Forgot Password</h1><p class="subtitle">Enter your email and we'll send a reset link</p>
<form method="POST" action="/auth/forgot-password"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required></div>
<button class="btn btn-primary btn-block">Send Reset Link</button></form>
<div class="auth-footer"><a href="/auth/login">Back to login</a></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_FORGOT_EOF

cat > views/customer/reset-password.ejs <<'AGH_C_RESET_EOF'
<%- include('../partials/header') %>
<div class="auth-wrap"><div class="auth-card">
<h1>Reset Password</h1><p class="subtitle">Choose your new password</p>
<form method="POST" action="/auth/reset/<%= token %>"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">New Password</label><input type="password" name="password" class="form-input" required minlength="8"></div>
<button class="btn btn-primary btn-block">Reset Password</button></form>
</div></div>
<%- include('../partials/footer') %>
AGH_C_RESET_EOF

cat > views/customer/dashboard.ejs <<'AGH_C_DASH_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar">
<div class="profile"><div class="avatar"><% if (currentUser.avatar) { %><img src="<%= currentUser.avatar %>"><% } else { %><%= currentUser.name.charAt(0).toUpperCase() %><% } %></div><div style="font-weight:700;"><%= currentUser.name %></div><div class="text-muted" style="font-size:0.8rem;"><%= currentUser.email %></div></div>
<nav class="dash-nav"><a href="/dashboard" class="active"><i class="fas fa-home"></i> Dashboard</a><a href="/services"><i class="fas fa-server"></i> My Services</a><a href="/orders"><i class="fas fa-shopping-bag"></i> Orders</a><a href="/invoices"><i class="fas fa-file-invoice"></i> Invoices</a><a href="/tickets"><i class="fas fa-headset"></i> Support Tickets</a><a href="/notifications"><i class="fas fa-bell"></i> Notifications</a><a href="/profile"><i class="fas fa-user"></i> Profile</a><a href="/settings"><i class="fas fa-cog"></i> Settings</a>
<form method="POST" action="/auth/logout" style="margin-top:8px;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button style="width:100%;padding:10px 14px;background:none;border:none;text-align:left;color:var(--error);cursor:pointer;border-radius:8px;"><i class="fas fa-sign-out-alt"></i> Logout</button></form></nav>
</aside>
<div class="dash-content">
<h1>Welcome, <%= currentUser.name.split(' ')[0] %>!</h1>
<div class="stat-cards">
<div class="stat-card"><div class="icon"><i class="fas fa-shopping-bag"></i></div><div class="value"><%= stats.totalOrders %></div><div class="label">Total Orders</div></div>
<div class="stat-card"><div class="icon"><i class="fas fa-dollar-sign"></i></div><div class="value">$<%= stats.totalSpent.toFixed(2) %></div><div class="label">Total Spent</div></div>
<div class="stat-card"><div class="icon"><i class="fas fa-server"></i></div><div class="value"><%= stats.activeServices %></div><div class="label">Active Services</div></div>
<div class="stat-card"><div class="icon"><i class="fas fa-ticket-alt"></i></div><div class="value"><%= stats.openTickets %></div><div class="label">Open Tickets</div></div>
</div>
<div class="grid grid-2">
<div class="card"><h3 class="mb-2">Recent Orders</h3>
<% if (orders.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Order #</th><th>Total</th><th>Status</th><th></th></tr></thead><tbody><% orders.forEach(o => { %><tr><td><%= o.order_number %></td><td>$<%= o.total.toFixed(2) %></td><td><span class="badge badge-<%= o.status === 'completed' ? 'success' : 'warning' %>"><%= o.status %></span></td><td><a href="/orders/<%= o.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty-state"><i class="fas fa-shopping-bag"></i><p>No orders yet.</p></div><% } %>
</div>
<div class="card"><h3 class="mb-2">My Services</h3>
<% if (services.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Service</th><th>Status</th></tr></thead><tbody><% services.forEach(s => { %><tr><td><%= s.product_name %></td><td><span class="badge badge-<%= s.status === 'active' ? 'success' : 'warning' %>"><%= s.status %></span></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty-state"><i class="fas fa-server"></i><p>No services yet.</p><a href="/products" class="btn btn-primary">Browse Plans</a></div><% } %>
</div></div>
<div class="card mt-3"><h3 class="mb-2">Recent Tickets</h3>
<% if (tickets.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Ticket</th><th>Subject</th><th>Status</th><th></th></tr></thead><tbody><% tickets.forEach(t => { %><tr><td><%= t.ticket_number %></td><td><%= t.subject %></td><td><span class="badge badge-<%= t.status === 'open' ? 'warning' : 'success' %>"><%= t.status %></span></td><td><a href="/tickets/<%= t.id %>" class="btn btn-outline btn-sm">Open</a></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty-state"><i class="fas fa-headset"></i><p>No tickets.</p><a href="/tickets" class="btn btn-primary">Create Ticket</a></div><% } %>
</div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_DASH_EOF

cat > views/customer/profile.ejs <<'AGH_C_PROFILE_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><% if (currentUser.avatar) { %><img src="<%= currentUser.avatar %>"><% } else { %><%= currentUser.name.charAt(0).toUpperCase() %><% } %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/profile" class="active"><i class="fas fa-user"></i> Profile</a><a href="/settings"><i class="fas fa-cog"></i> Settings</a><a href="/orders"><i class="fas fa-shopping-bag"></i> Orders</a><a href="/invoices"><i class="fas fa-file-invoice"></i> Invoices</a><a href="/tickets"><i class="fas fa-headset"></i> Tickets</a></nav></aside>
<div class="dash-content"><h1>My Profile</h1>
<div class="card"><form method="POST" action="/profile" enctype="multipart/form-data"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Profile Picture</label><input type="file" name="avatar" class="form-input" accept="image/*"></div>
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" value="<%= currentUser.name %>" required></div>
<div class="form-group"><label class="form-label">Email (cannot change)</label><input type="email" class="form-input" value="<%= currentUser.email %>" disabled></div>
<div class="form-group"><label class="form-label">Phone</label><input type="text" name="phone" class="form-input" value="<%= currentUser.phone || '' %>"></div>
<div class="form-group"><label class="form-label">Address</label><input type="text" name="address" class="form-input" value="<%= currentUser.address || '' %>"></div>
<div class="form-group"><label class="form-label">City</label><input type="text" name="city" class="form-input" value="<%= currentUser.city || '' %>"></div>
<div class="form-group"><label class="form-label">Country</label><input type="text" name="country" class="form-input" value="<%= currentUser.country || '' %>"></div>
<button class="btn btn-primary"><i class="fas fa-save"></i> Save Changes</button></form></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_PROFILE_EOF

cat > views/customer/settings.ejs <<'AGH_C_SETTINGS_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/profile"><i class="fas fa-user"></i> Profile</a><a href="/settings" class="active"><i class="fas fa-cog"></i> Settings</a></nav></aside>
<div class="dash-content"><h1>Account Settings</h1>
<div class="card mb-3"><h3 class="mb-2">Change Password</h3>
<form method="POST" action="/settings/password"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Current Password</label><input type="password" name="current_password" class="form-input" required></div>
<div class="form-group"><label class="form-label">New Password</label><input type="password" name="new_password" class="form-input" minlength="8" required></div>
<button class="btn btn-primary">Update Password</button></form></div>
<div class="card"><h3 class="mb-2">Theme Preference</h3><p class="text-muted" style="font-size:0.85rem;margin-bottom:16px;">Choose your preferred theme.</p>
<form method="POST" action="/settings/theme"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><select name="theme" class="form-select"><% themes.forEach(t => { %><option value="<%= t.slug %>" <%= currentUser.theme === t.slug ? 'selected' : '' %>><%= t.name %></option><% }) %></select></div>
<button class="btn btn-primary">Save Theme</button></form></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_SETTINGS_EOF

cat > views/customer/cart.ejs <<'AGH_C_CART_EOF'
<%- include('../partials/header') %>
<div class="cart-grid">
<div><h1 style="margin-bottom:24px;">Shopping Cart</h1>
<% if (!cart.length) { %><div class="empty-state"><i class="fas fa-shopping-cart"></i><h3>Your cart is empty</h3><p>Browse our plans to get started.</p><a href="/products" class="btn btn-primary">Browse Plans</a></div><% } else { %>
<% cart.forEach((item, i) => { %><div class="cart-item"><div class="item-info"><h3><%= item.product_name %></h3><div class="item-meta"><%= item.billing_cycle %> billing · $<%= item.price.toFixed(2) %> each</div></div>
<form method="POST" action="/cart/update/<%= i %>" style="display:flex;gap:6px;align-items:center;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><input type="number" name="quantity" value="<%= item.quantity %>" min="0" max="10" style="width:70px;" class="form-input"><button class="btn btn-outline btn-sm">Update</button></form>
<form method="POST" action="/cart/remove/<%= i %>"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm"><i class="fas fa-trash"></i></button></form>
</div><% }) %><% } %></div>
<% if (cart.length) { %><div class="cart-summary"><h2>Order Summary</h2>
<div class="summary-row"><span>Subtotal</span><span>$<%= subtotal.toFixed(2) %></span></div>
<form method="POST" action="/cart/apply-coupon" class="mt-2"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><div style="display:flex;gap:6px;"><input type="text" name="coupon_code" class="form-input" placeholder="Coupon code"><button class="btn btn-outline btn-sm">Apply</button></div></form>
<div class="summary-row total"><span>Total</span><span>$<%= total.toFixed(2) %></span></div>
<a href="/checkout" class="btn btn-primary btn-block mt-3"><i class="fas fa-lock"></i> Proceed to Checkout</a></div><% } %>
</div>
<%- include('../partials/footer') %>
AGH_C_CART_EOF

cat > views/customer/checkout.ejs <<'AGH_C_CHK_EOF'
<%- include('../partials/header') %>
<div class="cart-grid">
<div><h1 style="margin-bottom:24px;">Checkout</h1>
<form method="POST" action="/checkout"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="card mb-3"><h3 class="mb-2">Billing Details</h3>
<div class="form-group"><label class="form-label">Name</label><input type="text" class="form-input" value="<%= currentUser.name %>" disabled></div>
<div class="form-group"><label class="form-label">Email</label><input type="email" class="form-input" value="<%= currentUser.email %>" disabled></div>
<div class="form-group"><label class="form-label">Order Notes (optional)</label><textarea name="notes" class="form-textarea"></textarea></div>
</div>
<div class="card mb-3"><h3 class="mb-2">Payment Method</h3>
<% gateways.forEach(g => { %><label class="form-checkbox" style="padding:10px;border:1px solid var(--border);border-radius:8px;margin-bottom:8px;width:100%;"><input type="radio" name="payment_gateway" value="<%= g %>" <%= g === activeGateway ? 'checked' : '' %> required><span style="text-transform:capitalize;"><%= g.replace('_',' ') %></span></label><% }) %>
</div>
<button class="btn btn-primary btn-lg btn-block"><i class="fas fa-lock"></i> Place Order</button>
</form></div>
<div class="cart-summary"><h2>Order Summary</h2>
<% cart.forEach(item => { %><div class="summary-row"><span><%= item.product_name %> × <%= item.quantity %></span><span>$<%= (item.price * item.quantity).toFixed(2) %></span></div><% }) %>
<div class="summary-row"><span>Subtotal</span><span>$<%= subtotal.toFixed(2) %></span></div>
<% if (discount > 0) { %><div class="summary-row" style="color:var(--success);"><span>Discount</span><span>-$<%= discount.toFixed(2) %></span></div><% } %>
<% if (tax > 0) { %><div class="summary-row"><span>Tax</span><span>$<%= tax.toFixed(2) %></span></div><% } %>
<div class="summary-row total"><span>Total</span><span>$<%= total.toFixed(2) %></span></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_CHK_EOF

cat > views/customer/pay-client.ejs <<'AGH_C_PAYC_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:600px;text-align:center;"><div class="card">
<h2>Processing Payment</h2><p class="text-muted mt-2">Complete your payment in the gateway window.</p>
<p class="mt-3">Order: <strong><%= order.order_number %></strong></p><p>Amount: <strong>$<%= order.total.toFixed(2) %></strong></p>
<% if (result.gateway === 'razorpay') { %>
<script src="https://checkout.razorpay.com/v1/checkout.js"></script>
<button id="rzpBtn" class="btn btn-primary btn-lg mt-3">Pay with Razorpay</button>
<script>
var options = { key:"<%= result.key_id %>", amount:"<%= result.amount %>", currency:"<%= result.currency %>", name:"<%= settings.site_name %>", description:"Order <%= order.order_number %>", order_id:"<%= result.rzp_order_id %>",
handler:function(response){ var form=document.createElement('form'); form.method='POST'; form.action='/checkout/razorpay-verify';
var fields={_csrf:'<%= csrfToken %>',order_id:'<%= order.id %>',razorpay_payment_id:response.razorpay_payment_id,razorpay_signature:response.razorpay_signature};
for(var k in fields){var i=document.createElement('input'); i.type='hidden'; i.name=k; i.value=fields[k]; form.appendChild(i);} document.body.appendChild(form); form.submit(); }};
var rzp = new Razorpay(options); document.getElementById('rzpBtn').onclick=function(e){ e.preventDefault(); rzp.open(); };
</script>
<% } %>
<a href="/orders/<%= order.id %>" class="btn btn-outline mt-3">View Order</a>
</div></section>
<%- include('../partials/footer') %>
AGH_C_PAYC_EOF

cat > views/customer/pay-manual.ejs <<'AGH_C_PAYM_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:700px;"><div class="card">
<h2 style="margin-bottom:12px;">Complete Payment</h2>
<p class="text-muted mb-3">Order <strong><%= order.order_number %></strong> · Amount: <strong>$<%= order.total.toFixed(2) %></strong></p>
<% if (result.gateway === 'manual_upi') { %>
<h3 style="margin-bottom:12px;">Pay via UPI</h3>
<div style="background:var(--bg-2);padding:16px;border-radius:8px;margin-bottom:16px;"><p>UPI ID: <strong data-copy="<%= result.upi_id %>" style="cursor:pointer;"><%= result.upi_id %> <i class="fas fa-copy"></i></strong></p><p>Name: <strong><%= result.upi_name %></strong></p><p>Amount: <strong>$<%= result.amount.toFixed(2) %></strong></p><p>Reference: <strong><%= result.order_number %></strong></p></div>
<% } else if (result.gateway === 'manual_bank') { %>
<h3 style="margin-bottom:12px;">Bank Transfer</h3>
<div style="background:var(--bg-2);padding:16px;border-radius:8px;margin-bottom:16px;line-height:2;"><p>Bank: <strong><%= result.bank.bank_name %></strong></p><p>Account: <strong><%= result.bank.account_name %></strong></p><p>Number: <strong><%= result.bank.account_number %></strong></p><p>IFSC: <strong><%= result.bank.ifsc %></strong></p><p>Amount: <strong>$<%= result.amount.toFixed(2) %></strong></p><p>Reference: <strong><%= result.order_number %></strong></p></div>
<% } else { %><p class="text-muted"><%= result.message || 'Contact support to complete payment.' %></p><% } %>
<div class="announcement-banner"><i class="fas fa-info-circle"></i> After payment, our team will verify within 1-24 hours.</div>
<a href="/orders/<%= order.id %>" class="btn btn-primary mt-3">View Order</a>
</div></section>
<%- include('../partials/footer') %>
AGH_C_PAYM_EOF

cat > views/customer/order-confirmation.ejs <<'AGH_C_OC_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:700px;text-align:center;"><div class="card">
<i class="fas fa-check-circle" style="font-size:4rem;color:var(--success);margin-bottom:20px;"></i>
<h1>Order Received!</h1>
<p class="text-muted mt-2">Order <strong><%= order.order_number %></strong> has been created.</p>
<p class="text-muted">We will notify you once payment is confirmed.</p>
<div class="mt-4"><a href="/orders/<%= order.id %>" class="btn btn-primary">View Order</a> <a href="/dashboard" class="btn btn-outline">Dashboard</a></div>
</div></section>
<%- include('../partials/footer') %>
AGH_C_OC_EOF

cat > views/customer/orders.ejs <<'AGH_C_ORDERS_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/orders" class="active"><i class="fas fa-shopping-bag"></i> Orders</a><a href="/invoices"><i class="fas fa-file-invoice"></i> Invoices</a><a href="/services"><i class="fas fa-server"></i> Services</a><a href="/tickets"><i class="fas fa-headset"></i> Tickets</a></nav></aside>
<div class="dash-content"><h1>My Orders</h1>
<% if (!orders.length) { %><div class="empty-state"><i class="fas fa-shopping-bag"></i><p>No orders yet.</p><a href="/products" class="btn btn-primary">Browse Plans</a></div><% } else { %>
<div class="table-wrap"><table class="table"><thead><tr><th>Order #</th><th>Date</th><th>Total</th><th>Status</th><th>Payment</th><th></th></tr></thead><tbody>
<% orders.forEach(o => { %><tr><td><strong><%= o.order_number %></strong></td><td><%= new Date(o.created_at*1000).toLocaleDateString() %></td><td>$<%= o.total.toFixed(2) %></td><td><span class="badge badge-<%= o.status === 'completed' ? 'success' : o.status === 'cancelled' ? 'error' : 'warning' %>"><%= o.status %></span></td><td><span class="badge badge-<%= o.payment_status === 'paid' ? 'success' : 'warning' %>"><%= o.payment_status %></span></td><td><a href="/orders/<%= o.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %>
</tbody></table></div><% } %>
</div></div>
<%- include('../partials/footer') %>
AGH_C_ORDERS_EOF

cat > views/customer/order-details.ejs <<'AGH_C_OD_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/orders" class="active"><i class="fas fa-shopping-bag"></i> Orders</a><a href="/invoices"><i class="fas fa-file-invoice"></i> Invoices</a></nav></aside>
<div class="dash-content"><h1>Order <%= order.order_number %></h1>
<div class="grid grid-2 mb-3">
<div class="card"><h3 class="mb-2">Status</h3><p>Order: <span class="badge badge-<%= order.status === 'completed' ? 'success' : 'warning' %>"><%= order.status %></span></p><p class="mt-2">Payment: <span class="badge badge-<%= order.payment_status === 'paid' ? 'success' : 'warning' %>"><%= order.payment_status %></span></p></div>
<div class="card"><h3 class="mb-2">Amount</h3><p>Subtotal: $<%= order.subtotal.toFixed(2) %></p><% if (order.discount > 0) { %><p>Discount: -$<%= order.discount.toFixed(2) %></p><% } %><p>Tax: $<%= order.tax.toFixed(2) %></p><p style="font-size:1.3rem;font-weight:800;margin-top:8px;">Total: $<%= order.total.toFixed(2) %></p></div>
</div>
<div class="card mb-3"><h3 class="mb-2">Items</h3><div class="table-wrap"><table class="table"><thead><tr><th>Product</th><th>Billing</th><th>Qty</th><th>Price</th></tr></thead><tbody><% items.forEach(i => { %><tr><td><%= i.product_name %></td><td><%= i.billing_cycle %></td><td><%= i.quantity %></td><td>$<%= i.price.toFixed(2) %></td></tr><% }) %></tbody></table></div></div>
<% if (payments.length) { %><div class="card mb-3"><h3 class="mb-2">Payments</h3><div class="table-wrap"><table class="table"><thead><tr><th>Gateway</th><th>Txn ID</th><th>Amount</th><th>Status</th><th>Date</th></tr></thead><tbody><% payments.forEach(p => { %><tr><td><%= p.gateway %></td><td><%= p.transaction_id || '—' %></td><td>$<%= p.amount.toFixed(2) %></td><td><span class="badge badge-<%= p.status === 'success' ? 'success' : p.status === 'failed' ? 'error' : 'warning' %>"><%= p.status %></span></td><td><%= new Date(p.created_at*1000).toLocaleString() %></td></tr><% }) %></tbody></table></div></div><% } %>
<% if (invoice) { %><a href="/invoices/<%= invoice.id %>" class="btn btn-outline"><i class="fas fa-file-invoice"></i> View Invoice</a><% } %>
</div></div>
<%- include('../partials/footer') %>
AGH_C_OD_EOF

cat > views/customer/invoices.ejs <<'AGH_C_INV_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/orders"><i class="fas fa-shopping-bag"></i> Orders</a><a href="/invoices" class="active"><i class="fas fa-file-invoice"></i> Invoices</a></nav></aside>
<div class="dash-content"><h1>Invoices</h1>
<% if (!invoices.length) { %><div class="empty-state"><i class="fas fa-file-invoice"></i><p>No invoices yet.</p></div><% } else { %>
<div class="table-wrap"><table class="table"><thead><tr><th>Invoice #</th><th>Order</th><th>Amount</th><th>Status</th><th>Date</th><th></th></tr></thead><tbody>
<% invoices.forEach(i => { %><tr><td><strong><%= i.invoice_number %></strong></td><td><%= i.order_number %></td><td>$<%= i.amount.toFixed(2) %></td><td><span class="badge badge-<%= i.status === 'paid' ? 'success' : 'warning' %>"><%= i.status %></span></td><td><%= new Date(i.issued_at*1000).toLocaleDateString() %></td><td><a href="/invoices/<%= i.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %>
</tbody></table></div><% } %>
</div></div>
<%- include('../partials/footer') %>
AGH_C_INV_EOF

cat > views/customer/invoice-view.ejs <<'AGH_C_INVVIEW_EOF'
<%- include('../partials/header') %>
<section class="section" style="max-width:800px;"><div class="card">
<div style="display:flex;justify-content:space-between;align-items:start;margin-bottom:24px;">
<div><h2 style="font-size:1.5rem;"><%= settings.site_name %></h2><p class="text-muted" style="font-size:0.85rem;"><%= settings.contact_email %></p></div>
<div style="text-align:right;"><h3>INVOICE</h3><p class="text-muted"><%= invoice.invoice_number %></p><p class="text-muted"><%= new Date(invoice.issued_at*1000).toLocaleDateString() %></p></div>
</div>
<p class="mb-3"><strong>Bill To:</strong> <%= currentUser.name %> &lt;<%= currentUser.email %>&gt;</p>
<div class="table-wrap mb-3"><table class="table"><thead><tr><th>Item</th><th>Qty</th><th>Price</th></tr></thead><tbody><% items.forEach(i => { %><tr><td><%= i.product_name %></td><td><%= i.quantity %></td><td>$<%= i.price.toFixed(2) %></td></tr><% }) %></tbody><tfoot><tr><td colspan="2" style="text-align:right;font-weight:700;">Total:</td><td style="font-weight:800;">$<%= invoice.amount.toFixed(2) %></td></tr></tfoot></table></div>
<div class="text-center"><button onclick="window.print()" class="btn btn-outline"><i class="fas fa-print"></i> Print</button></div>
</div></section>
<%- include('../partials/footer') %>
AGH_C_INVVIEW_EOF

cat > views/customer/services.ejs <<'AGH_C_SVC_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/services" class="active"><i class="fas fa-server"></i> Services</a><a href="/orders"><i class="fas fa-shopping-bag"></i> Orders</a></nav></aside>
<div class="dash-content"><h1>My Services</h1>
<% if (!services.length) { %><div class="empty-state"><i class="fas fa-server"></i><p>No active services yet.</p><a href="/products" class="btn btn-primary">Get Started</a></div><% } else { %>
<div class="grid grid-3"><% services.forEach(s => { %><div class="card"><h3><%= s.product_name %></h3><p class="text-muted" style="font-size:0.85rem;margin-bottom:12px;">Order #<%= s.order_id || '—' %></p><p>Status: <span class="badge badge-<%= s.status === 'active' ? 'success' : 'warning' %>"><%= s.status %></span></p><p class="mt-2" style="font-size:0.85rem;">Billing: <%= s.billing_cycle || 'monthly' %></p><% if (s.renews_at) { %><p style="font-size:0.85rem;">Renews: <%= new Date(s.renews_at*1000).toLocaleDateString() %></p><% } %></div><% }) %></div>
<% } %></div></div>
<%- include('../partials/footer') %>
AGH_C_SVC_EOF

cat > views/customer/tickets.ejs <<'AGH_C_TKTS_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div><div style="font-weight:700;"><%= currentUser.name %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/tickets" class="active"><i class="fas fa-headset"></i> Tickets</a></nav></aside>
<div class="dash-content"><h1>Support Tickets</h1>
<div class="grid grid-2">
<div class="card"><h3 class="mb-2">Create New Ticket</h3>
<form method="POST" action="/tickets"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Subject</label><input type="text" name="subject" class="form-input" required></div>
<div class="form-group"><label class="form-label">Category</label><select name="category" class="form-select"><option value="general">General</option><option value="technical">Technical</option><option value="billing">Billing</option><option value="abuse">Abuse</option></select></div>
<div class="form-group"><label class="form-label">Priority</label><select name="priority" class="form-select"><option value="low">Low</option><option value="normal" selected>Normal</option><option value="high">High</option><option value="urgent">Urgent</option></select></div>
<div class="form-group"><label class="form-label">Message</label><textarea name="message" class="form-textarea" required></textarea></div>
<button class="btn btn-primary"><i class="fas fa-paper-plane"></i> Create Ticket</button></form></div>
<div class="card"><h3 class="mb-2">My Tickets</h3>
<% if (!tickets.length) { %><p class="text-muted">No tickets yet.</p><% } else { %><% tickets.forEach(t => { %><a href="/tickets/<%= t.id %>" style="display:block;padding:12px;border:1px solid var(--border);border-radius:8px;margin-bottom:8px;color:var(--text);"><div style="display:flex;justify-content:space-between;"><strong><%= t.subject %></strong><span class="badge badge-<%= t.status === 'open' ? 'warning' : 'success' %>"><%= t.status %></span></div><div style="font-size:0.8rem;color:var(--muted);margin-top:4px;"><%= t.ticket_number %> · <%= new Date(t.created_at*1000).toLocaleDateString() %></div></a><% }) %><% } %></div>
</div></div></div>
<%- include('../partials/footer') %>
AGH_C_TKTS_EOF

cat > views/customer/ticket-details.ejs <<'AGH_C_TKTD_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/tickets" class="active"><i class="fas fa-headset"></i> Tickets</a></nav></aside>
<div class="dash-content"><h1><%= ticket.subject %></h1>
<p class="text-muted mb-3"><%= ticket.ticket_number %> · Status: <span class="badge badge-<%= ticket.status === 'open' ? 'warning' : 'success' %>"><%= ticket.status %></span></p>
<% messages.forEach(m => { %><div class="card mb-2" style="<%= m.is_admin ? 'border-color:var(--primary);' : '' %>"><div style="display:flex;justify-content:space-between;margin-bottom:8px;"><strong><%= m.author || 'User' %><%= m.is_admin ? ' (Staff)' : '' %></strong><span class="text-muted" style="font-size:0.8rem;"><%= new Date(m.created_at*1000).toLocaleString() %></span></div><p style="white-space:pre-wrap;"><%= m.message %></p></div><% }) %>
<div class="card mt-3"><h3 class="mb-2">Reply</h3>
<form method="POST" action="/tickets/<%= ticket.id %>/reply"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><textarea name="message" class="form-textarea" required placeholder="Type your reply..."></textarea></div>
<button class="btn btn-primary"><i class="fas fa-paper-plane"></i> Send Reply</button></form></div>
</div></div>
<%- include('../partials/footer') %>
AGH_C_TKTD_EOF

cat > views/customer/notifications.ejs <<'AGH_C_NOTIF_EOF'
<%- include('../partials/header') %>
<div class="dash-wrap">
<aside class="dash-sidebar"><div class="profile"><div class="avatar"><%= currentUser.name.charAt(0).toUpperCase() %></div></div>
<nav class="dash-nav"><a href="/dashboard"><i class="fas fa-home"></i> Dashboard</a><a href="/notifications" class="active"><i class="fas fa-bell"></i> Notifications</a></nav></aside>
<div class="dash-content"><h1>Notifications</h1>
<% if (!notifications.length) { %><div class="empty-state"><i class="fas fa-bell"></i><p>No notifications.</p></div><% } else { %><% notifications.forEach(n => { %><div class="card mb-2"><div style="display:flex;justify-content:space-between;"><strong><%= n.title %></strong><span class="text-muted" style="font-size:0.8rem;"><%= new Date(n.created_at*1000).toLocaleString() %></span></div><p class="mt-1 text-muted"><%= n.message %></p><% if (n.link) { %><a href="<%= n.link %>" class="btn btn-outline btn-sm mt-2">View</a><% } %></div><% }) %><% } %>
</div></div>
<%- include('../partials/footer') %>
AGH_C_NOTIF_EOF
log "All customer views written"

# ============================================================
# 11. ADMIN VIEWS
# ============================================================
step "Writing admin EJS views"

cat > views/admin/login.ejs <<'AGH_A_LOGIN_EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Admin Login · AG Tech Hosting</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
<link rel="stylesheet" href="/css/admin.css"></head><body>
<div class="admin-login-wrap"><div class="admin-login-card">
<div class="logo"><div class="logo-icon">AG</div></div>
<h1>Admin Login</h1><p class="sub">Sign in to the control panel</p>
<% if (flashError && flashError.length) { %><div class="flash error mb-2"><%= flashError[0] %></div><% } %>
<form method="POST" action="/admin/login"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required autofocus></div>
<div class="form-group"><label class="form-label">Password</label><input type="password" name="password" class="form-input" required></div>
<button class="btn btn-primary btn-block">Log In</button></form>
</div></div></body></html>
AGH_A_LOGIN_EOF

cat > views/admin/dashboard.ejs <<'AGH_A_DASH_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Dashboard</h1><p>Overview of your hosting business</p></div><a href="/admin/orders" class="btn btn-primary"><i class="fas fa-shopping-bag"></i> View Orders</a></div>
<div class="stat-grid">
<div class="stat-box primary"><div class="lbl">Total Revenue</div><div class="val">$<%= stats.totalRevenue.toFixed(2) %></div></div>
<div class="stat-box"><div class="lbl">Total Customers</div><div class="val"><%= stats.totalCustomers %></div></div>
<div class="stat-box"><div class="lbl">Total Orders</div><div class="val"><%= stats.totalOrders %></div></div>
<div class="stat-box warning"><div class="lbl">Pending Orders</div><div class="val"><%= stats.pendingOrders %></div></div>
<div class="stat-box success"><div class="lbl">Completed</div><div class="val"><%= stats.completedOrders %></div></div>
<div class="stat-box"><div class="lbl">Active Products</div><div class="val"><%= stats.activeProducts %></div></div>
</div>
<div class="card mb-3"><h3 class="card-title">Revenue (Last 7 Days)</h3>
<div class="bar-chart"><% const maxV = Math.max(...salesChart.map(d=>d.total),1); %><% salesChart.forEach(d => { %><div class="bar"><div class="val">$<%= d.total.toFixed(0) %></div><div class="fill" data-height="<%= (d.total/maxV*100).toFixed(0) %>" style="height:<%= (d.total/maxV*100).toFixed(0) %>%"></div><div class="lbl"><%= d.day %></div></div><% }) %></div>
</div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Recent Orders</h3>
<% if (recentOrders.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Order</th><th>Customer</th><th>Total</th><th>Status</th><th></th></tr></thead><tbody><% recentOrders.forEach(o => { %><tr><td><%= o.order_number %></td><td><%= o.customer %></td><td>$<%= o.total.toFixed(2) %></td><td><span class="badge badge-<%= o.status === 'completed' ? 'success' : 'warning' %>"><%= o.status %></span></td><td><a href="/admin/orders/<%= o.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty"><i class="fas fa-inbox"></i><p>No orders yet.</p></div><% } %>
</div>
<div class="card"><h3 class="card-title">Recent Customers</h3>
<% if (recentUsers.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Name</th><th>Email</th></tr></thead><tbody><% recentUsers.forEach(u => { %><tr><td><%= u.name %></td><td><%= u.email %></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty"><i class="fas fa-users"></i><p>No customers yet.</p></div><% } %>
</div></div>
<%- include('../partials/admin-footer') %>
AGH_A_DASH_EOF

cat > views/admin/categories.ejs <<'AGH_A_CATS_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Categories</h1><p>Manage hosting categories</p></div></div>
<div class="grid-2 mb-3" style="align-items:start;">
<div class="card"><h3 class="card-title">Add Category</h3>
<form method="POST" action="/admin/categories"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" required></div>
<div class="form-group"><label class="form-label">Slug (optional)</label><input type="text" name="slug" class="form-input" placeholder="auto-generated"></div>
<div class="form-group"><label class="form-label">Description</label><textarea name="description" class="form-textarea"></textarea></div>
<div class="form-group"><label class="form-label">Icon (Font Awesome)</label><input type="text" name="icon" class="form-input" placeholder="fa-server"></div>
<div class="form-group"><label class="form-label">Sort Order</label><input type="number" name="sort_order" class="form-input" value="0"></div>
<div class="form-checkbox"><input type="checkbox" name="visible" checked><span>Visible</span></div>
<button class="btn btn-primary mt-2"><i class="fas fa-plus"></i> Add Category</button></form>
</div>
<div class="card"><h3 class="card-title">All Categories (<%= categories.length %>)</h3>
<div class="table-wrap"><table class="table"><thead><tr><th>Name</th><th>Slug</th><th>Visible</th><th>Actions</th></tr></thead><tbody>
<% categories.forEach(c => { %><tr>
<td><%= c.name %></td><td><%= c.slug %></td><td><span class="badge badge-<%= c.visible ? 'success' : 'error' %>"><%= c.visible ? 'Yes' : 'No' %></span></td>
<td><div class="actions">
<form method="POST" action="/admin/categories/<%= c.id %>" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><input type="hidden" name="name" value="<%= c.name %>"><input type="hidden" name="slug" value="<%= c.slug %>"><input type="hidden" name="description" value="<%= c.description || '' %>"><input type="hidden" name="icon" value="<%= c.icon || '' %>"><input type="hidden" name="sort_order" value="<%= c.sort_order %>"><input type="hidden" name="visible" value="<%= c.visible ? 'on' : '' %>"><button class="btn btn-outline btn-sm"><i class="fas fa-save"></i></button></form>
<form method="POST" action="/admin/categories/<%= c.id %>/delete" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm" data-confirm="Delete category and all its products?"><i class="fas fa-trash"></i></button></form>
</div></td></tr><% }) %>
</tbody></table></div></div></div>
<%- include('../partials/admin-footer') %>
AGH_A_CATS_EOF

cat > views/admin/products.ejs <<'AGH_A_PRODS_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Products</h1><p>Manage all hosting plans</p></div><a href="/admin/products/add" class="btn btn-primary"><i class="fas fa-plus"></i> Add Product</a></div>
<div class="table-wrap"><table class="table"><thead><tr><th>Name</th><th>Category</th><th>Price</th><th>Stock</th><th>Status</th><th>Actions</th></tr></thead><tbody>
<% products.forEach(p => { %><tr><td><strong><%= p.name %></strong><br><small class="text-muted"><%= p.slug %></small></td><td><%= p.category_name %></td><td>$<%= p.price_monthly.toFixed(2) %></td><td><%= p.stock >= 0 ? p.stock : '∞' %></td><td><span class="badge badge-<%= p.status === 'published' ? 'success' : 'warning' %>"><%= p.status %></span></td><td><div class="actions"><a href="/admin/products/<%= p.id %>/edit" class="btn btn-outline btn-sm"><i class="fas fa-edit"></i></a><form method="POST" action="/admin/products/<%= p.id %>/delete" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm" data-confirm="Delete product?"><i class="fas fa-trash"></i></button></form></div></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_PRODS_EOF

cat > views/admin/product-add.ejs <<'AGH_A_PADD_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Add Product</h1></div><a href="/admin/products" class="btn btn-outline">Back</a></div>
<div class="card"><form method="POST" action="/admin/products" enctype="multipart/form-data">
<input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-row">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" required></div>
<div class="form-group"><label class="form-label">Slug</label><input type="text" name="slug" class="form-input" placeholder="auto"></div>
<div class="form-group"><label class="form-label">Category</label><select name="category_id" class="form-select" required><% categories.forEach(c => { %><option value="<%= c.id %>"><%= c.name %></option><% }) %></select></div>
</div>
<div class="form-group"><label class="form-label">Description</label><textarea name="description" class="form-textarea"></textarea></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Monthly Price</label><input type="number" name="price_monthly" step="0.01" class="form-input" required></div>
<div class="form-group"><label class="form-label">Quarterly Price</label><input type="number" name="price_quarterly" step="0.01" class="form-input"></div>
<div class="form-group"><label class="form-label">Yearly Price</label><input type="number" name="price_yearly" step="0.01" class="form-input"></div>
</div>
<div class="form-row">
<div class="form-group"><label class="form-label">CPU</label><input type="text" name="cpu" class="form-input" placeholder="2 vCPU"></div>
<div class="form-group"><label class="form-label">RAM</label><input type="text" name="ram" class="form-input" placeholder="4 GB"></div>
<div class="form-group"><label class="form-label">Storage</label><input type="text" name="storage" class="form-input" placeholder="20 GB NVMe"></div>
</div>
<div class="form-row">
<div class="form-group"><label class="form-label">Bandwidth</label><input type="text" name="bandwidth" class="form-input" placeholder="Unmetered"></div>
<div class="form-group"><label class="form-label">Network</label><input type="text" name="network" class="form-input" placeholder="1 Gbps"></div>
<div class="form-group"><label class="form-label">Location</label><input type="text" name="location" class="form-input" placeholder="India"></div>
<div class="form-group"><label class="form-label">OS</label><input type="text" name="os" class="form-input" placeholder="Ubuntu 22.04"></div>
</div>
<div class="form-group"><label class="form-label">Features (JSON array)</label><input type="text" name="features" class="form-input" value='["DDoS Protection","Instant Setup"]'></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Stock (-1 = unlimited)</label><input type="number" name="stock" class="form-input" value="-1"></div>
<div class="form-group"><label class="form-label">Image</label><input type="file" name="image" class="form-input" accept="image/*"></div>
<div class="form-group"><label class="form-label">Status</label><select name="status" class="form-select"><option value="published">Published</option><option value="draft">Draft</option></select></div>
</div>
<div class="form-checkbox mb-2"><input type="checkbox" name="featured"><span>Featured</span></div>
<div class="form-checkbox mb-2"><input type="checkbox" name="popular"><span>Popular</span></div>
<button class="btn btn-primary"><i class="fas fa-save"></i> Create Product</button>
</form></div>
<%- include('../partials/admin-footer') %>
AGH_A_PADD_EOF

cat > views/admin/product-edit.ejs <<'AGH_A_PEDIT_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Edit Product</h1></div><a href="/admin/products" class="btn btn-outline">Back</a></div>
<div class="card"><form method="POST" action="/admin/products/<%= product.id %>" enctype="multipart/form-data">
<input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-row">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" value="<%= product.name %>" required></div>
<div class="form-group"><label class="form-label">Slug</label><input type="text" name="slug" class="form-input" value="<%= product.slug %>"></div>
<div class="form-group"><label class="form-label">Category</label><select name="category_id" class="form-select"><% categories.forEach(c => { %><option value="<%= c.id %>" <%= c.id === product.category_id ? 'selected' : '' %>><%= c.name %></option><% }) %></select></div>
</div>
<div class="form-group"><label class="form-label">Description</label><textarea name="description" class="form-textarea"><%= product.description || '' %></textarea></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Monthly Price</label><input type="number" name="price_monthly" step="0.01" class="form-input" value="<%= product.price_monthly %>"></div>
<div class="form-group"><label class="form-label">Quarterly Price</label><input type="number" name="price_quarterly" step="0.01" class="form-input" value="<%= product.price_quarterly || '' %>"></div>
<div class="form-group"><label class="form-label">Yearly Price</label><input type="number" name="price_yearly" step="0.01" class="form-input" value="<%= product.price_yearly || '' %>"></div>
</div>
<div class="form-row">
<div class="form-group"><label class="form-label">CPU</label><input type="text" name="cpu" class="form-input" value="<%= product.cpu || '' %>"></div>
<div class="form-group"><label class="form-label">RAM</label><input type="text" name="ram" class="form-input" value="<%= product.ram || '' %>"></div>
<div class="form-group"><label class="form-label">Storage</label><input type="text" name="storage" class="form-input" value="<%= product.storage || '' %>"></div>
</div>
<div class="form-row">
<div class="form-group"><label class="form-label">Bandwidth</label><input type="text" name="bandwidth" class="form-input" value="<%= product.bandwidth || '' %>"></div>
<div class="form-group"><label class="form-label">Network</label><input type="text" name="network" class="form-input" value="<%= product.network || '' %>"></div>
<div class="form-group"><label class="form-label">Location</label><input type="text" name="location" class="form-input" value="<%= product.location || '' %>"></div>
<div class="form-group"><label class="form-label">OS</label><input type="text" name="os" class="form-input" value="<%= product.os || '' %>"></div>
</div>
<div class="form-group"><label class="form-label">Features (JSON array)</label><input type="text" name="features" class="form-input" value='<%= product.features || "[]" %>'></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Stock</label><input type="number" name="stock" class="form-input" value="<%= product.stock %>"></div>
<div class="form-group"><label class="form-label">Image</label><input type="file" name="image" class="form-input" accept="image/*"><small class="text-muted">Current: <%= product.image || 'none' %></small></div>
<div class="form-group"><label class="form-label">Status</label><select name="status" class="form-select"><option value="published" <%= product.status === 'published' ? 'selected' : '' %>>Published</option><option value="draft" <%= product.status === 'draft' ? 'selected' : '' %>>Draft</option></select></div>
</div>
<div class="form-checkbox mb-2"><input type="checkbox" name="featured" <%= product.featured ? 'checked' : '' %>><span>Featured</span></div>
<div class="form-checkbox mb-2"><input type="checkbox" name="popular" <%= product.popular ? 'checked' : '' %>><span>Popular</span></div>
<button class="btn btn-primary"><i class="fas fa-save"></i> Save Changes</button>
</form></div>
<%- include('../partials/admin-footer') %>
AGH_A_PEDIT_EOF

cat > views/admin/customers.ejs <<'AGH_A_CUST_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Customers</h1><p>All registered customers</p></div></div>
<form method="GET" action="/admin/customers" class="mb-2" style="display:flex;gap:8px;max-width:400px;"><input type="text" name="q" class="form-input" placeholder="Search name or email" value="<%= q %>"><button class="btn btn-primary">Search</button></form>
<div class="table-wrap"><table class="table"><thead><tr><th>Name</th><th>Email</th><th>Status</th><th>Joined</th><th>Actions</th></tr></thead><tbody>
<% users.forEach(u => { %><tr><td><strong><%= u.name %></strong></td><td><%= u.email %></td><td><span class="badge badge-<%= u.status === 'active' ? 'success' : 'error' %>"><%= u.status %></span></td><td><%= new Date(u.created_at*1000).toLocaleDateString() %></td><td><a href="/admin/customers/<%= u.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_CUST_EOF

cat > views/admin/customer-details.ejs <<'AGH_A_CUSTD_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1><%= user.name %></h1><p><%= user.email %></p></div><a href="/admin/customers" class="btn btn-outline">Back</a></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Edit Customer</h3>
<form method="POST" action="/admin/customers/<%= user.id %>"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" value="<%= user.name %>"></div>
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" value="<%= user.email %>"></div>
<div class="form-group"><label class="form-label">Status</label><select name="status" class="form-select"><option value="active" <%= user.status === 'active' ? 'selected' : '' %>>Active</option><option value="suspended" <%= user.status === 'suspended' ? 'selected' : '' %>>Suspended</option></select></div>
<div class="form-group"><label class="form-label">Role</label><select name="role" class="form-select"><option value="customer" <%= user.role === 'customer' ? 'selected' : '' %>>Customer</option><option value="staff" <%= user.role === 'staff' ? 'selected' : '' %>>Staff</option><option value="admin" <%= user.role === 'admin' ? 'selected' : '' %>>Admin</option></select></div>
<button class="btn btn-primary">Save</button></form>
</div>
<div class="card"><h3 class="card-title">Summary</h3>
<p><strong>Orders:</strong> <%= orders.length %></p><p><strong>Services:</strong> <%= services.length %></p><p><strong>Tickets:</strong> <%= tickets.length %></p>
<p class="text-muted mt-2"><small>Joined <%= new Date(user.created_at*1000).toLocaleDateString() %></small></p></div>
</div>
<div class="card mb-3"><h3 class="card-title">Orders</h3>
<% if (orders.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Order</th><th>Total</th><th>Status</th><th></th></tr></thead><tbody><% orders.forEach(o => { %><tr><td><%= o.order_number %></td><td>$<%= o.total.toFixed(2) %></td><td><span class="badge badge-warning"><%= o.status %></span></td><td><a href="/admin/orders/<%= o.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty"><p>No orders.</p></div><% } %>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_CUSTD_EOF

cat > views/admin/orders.ejs <<'AGH_A_ORD_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Orders</h1><p>All orders</p></div></div>
<div class="tabs"><a href="/admin/orders" class="<%= !status ? 'active' : '' %>">All</a><a href="/admin/orders?status=pending" class="<%= status === 'pending' ? 'active' : '' %>">Pending</a><a href="/admin/orders?status=completed" class="<%= status === 'completed' ? 'active' : '' %>">Completed</a><a href="/admin/orders?status=cancelled" class="<%= status === 'cancelled' ? 'active' : '' %>">Cancelled</a></div>
<div class="table-wrap"><table class="table"><thead><tr><th>Order #</th><th>Customer</th><th>Total</th><th>Status</th><th>Payment</th><th>Date</th><th></th></tr></thead><tbody>
<% orders.forEach(o => { %><tr><td><strong><%= o.order_number %></strong></td><td><%= o.customer %></td><td>$<%= o.total.toFixed(2) %></td><td><span class="badge badge-<%= o.status === 'completed' ? 'success' : o.status === 'cancelled' ? 'error' : 'warning' %>"><%= o.status %></span></td><td><span class="badge badge-<%= o.payment_status === 'paid' ? 'success' : 'warning' %>"><%= o.payment_status %></span></td><td><%= new Date(o.created_at*1000).toLocaleDateString() %></td><td><a href="/admin/orders/<%= o.id %>" class="btn btn-outline btn-sm">View</a></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_ORD_EOF

cat > views/admin/order-details.ejs <<'AGH_A_ORDD_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Order <%= order.order_number %></h1><p><%= order.customer %> · <%= order.customer_email %></p></div><a href="/admin/orders" class="btn btn-outline">Back</a></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Update Status</h3>
<form method="POST" action="/admin/orders/<%= order.id %>/status"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Order Status</label><select name="status" class="form-select"><option value="pending" <%= order.status === 'pending' ? 'selected' : '' %>>Pending</option><option value="processing" <%= order.status === 'processing' ? 'selected' : '' %>>Processing</option><option value="completed" <%= order.status === 'completed' ? 'selected' : '' %>>Completed</option><option value="cancelled" <%= order.status === 'cancelled' ? 'selected' : '' %>>Cancelled</option><option value="refunded" <%= order.status === 'refunded' ? 'selected' : '' %>>Refunded</option></select></div>
<div class="form-group"><label class="form-label">Payment Status</label><select name="payment_status" class="form-select"><option value="unpaid" <%= order.payment_status === 'unpaid' ? 'selected' : '' %>>Unpaid</option><option value="pending_verification" <%= order.payment_status === 'pending_verification' ? 'selected' : '' %>>Pending Verification</option><option value="paid" <%= order.payment_status === 'paid' ? 'selected' : '' %>>Paid</option><option value="failed" <%= order.payment_status === 'failed' ? 'selected' : '' %>>Failed</option><option value="refunded" <%= order.payment_status === 'refunded' ? 'selected' : '' %>>Refunded</option></select></div>
<button class="btn btn-primary" data-confirm="Update order? Marking paid will provision services."><i class="fas fa-save"></i> Update Order</button></form>
</div>
<div class="card"><h3 class="card-title">Summary</h3>
<p><strong>Total:</strong> $<%= order.total.toFixed(2) %></p>
<p><strong>Gateway:</strong> <%= order.payment_gateway || '—' %></p>
<p><strong>Reference:</strong> <%= order.payment_ref || '—' %></p>
<p><strong>Created:</strong> <%= new Date(order.created_at*1000).toLocaleString() %></p></div>
</div>
<div class="card mb-3"><h3 class="card-title">Items</h3>
<div class="table-wrap"><table class="table"><thead><tr><th>Product</th><th>Billing</th><th>Qty</th><th>Price</th></tr></thead><tbody><% items.forEach(i => { %><tr><td><%= i.product_name %></td><td><%= i.billing_cycle %></td><td><%= i.quantity %></td><td>$<%= i.price.toFixed(2) %></td></tr><% }) %></tbody></table></div></div>
<div class="card"><h3 class="card-title">Payments</h3>
<% if (payments.length) { %><div class="table-wrap"><table class="table"><thead><tr><th>Gateway</th><th>Txn</th><th>Amount</th><th>Status</th><th>Date</th></tr></thead><tbody><% payments.forEach(p => { %><tr><td><%= p.gateway %></td><td><%= p.transaction_id || '—' %></td><td>$<%= p.amount.toFixed(2) %></td><td><span class="badge badge-<%= p.status === 'success' ? 'success' : p.status === 'failed' ? 'error' : 'warning' %>"><%= p.status %></span></td><td><%= new Date(p.created_at*1000).toLocaleString() %></td></tr><% }) %></tbody></table></div><% } else { %><div class="empty"><p>No payment records.</p></div><% } %>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_ORDD_EOF

cat > views/admin/payments.ejs <<'AGH_A_PAY_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Payments</h1></div></div>
<div class="table-wrap"><table class="table"><thead><tr><th>ID</th><th>Order</th><th>Customer</th><th>Gateway</th><th>Amount</th><th>Status</th><th>Date</th></tr></thead><tbody>
<% payments.forEach(p => { %><tr><td>#<%= p.id %></td><td><%= p.order_number %></td><td><%= p.customer %></td><td><%= p.gateway %></td><td>$<%= p.amount.toFixed(2) %></td><td><span class="badge badge-<%= p.status === 'success' ? 'success' : p.status === 'failed' ? 'error' : 'warning' %>"><%= p.status %></span></td><td><%= new Date(p.created_at*1000).toLocaleString() %></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_PAY_EOF

cat > views/admin/payment-settings.ejs <<'AGH_A_PAYSET_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Payment Settings</h1><p>Active: <strong><%= activeProvider %></strong></p></div></div>
<div class="announcement-banner" style="background:rgba(59,130,246,0.1);border-color:rgba(59,130,246,0.3);margin-bottom:20px;"><i class="fas fa-info-circle"></i> Active gateway set via <code>PAYMENT_PROVIDER</code> in <code>.env</code>.</div>
<% gateways.forEach(g => { %>
<div class="card mb-3"><h3 class="card-title"><%= g.name.replace('_',' ').toUpperCase() %> <span class="badge badge-<%= g.enabled ? 'success' : 'error' %>"><%= g.enabled ? 'Enabled' : 'Disabled' %></span></h3>
<form method="POST" action="/admin/payment-settings/<%= g.name %>"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-row">
<div class="form-group"><label class="form-label">Mode</label><select name="mode" class="form-select"><option value="test" <%= g.mode === 'test' ? 'selected' : '' %>>Test</option><option value="live" <%= g.mode === 'live' ? 'selected' : '' %>>Live</option><option value="sandbox" <%= g.mode === 'sandbox' ? 'selected' : '' %>>Sandbox</option></select></div>
<div class="form-group"><label class="form-label">Enabled</label><div class="form-checkbox" style="padding-top:12px;"><input type="checkbox" name="enabled" <%= g.enabled ? 'checked' : '' %>><span>Active</span></div></div>
</div>
<% if (g.name === 'razorpay') { %>
<div class="form-group"><label class="form-label">Key ID</label><input type="text" name="key_id" class="form-input" value="<%= g.config.key_id || '' %>"></div>
<div class="form-group"><label class="form-label">Key Secret</label><input type="password" name="key_secret" class="form-input" value="<%= g.config.key_secret || '' %>"></div>
<div class="form-group"><label class="form-label">Webhook Secret</label><input type="password" name="webhook_secret" class="form-input" value="<%= g.config.webhook_secret || '' %>"></div>
<% } else if (g.name === 'stripe') { %>
<div class="form-group"><label class="form-label">Secret Key</label><input type="password" name="secret_key" class="form-input" value="<%= g.config.secret_key || '' %>"></div>
<div class="form-group"><label class="form-label">Publishable Key</label><input type="text" name="publishable_key" class="form-input" value="<%= g.config.publishable_key || '' %>"></div>
<div class="form-group"><label class="form-label">Webhook Secret</label><input type="password" name="webhook_secret" class="form-input" value="<%= g.config.webhook_secret || '' %>"></div>
<% } else if (g.name === 'paypal') { %>
<div class="form-group"><label class="form-label">Client ID</label><input type="text" name="client_id" class="form-input" value="<%= g.config.client_id || '' %>"></div>
<div class="form-group"><label class="form-label">Client Secret</label><input type="password" name="client_secret" class="form-input" value="<%= g.config.client_secret || '' %>"></div>
<% } else if (g.name === 'cashfree' || g.name === 'phonepe') { %>
<div class="form-group"><label class="form-label">App/Client ID</label><input type="text" name="app_id" class="form-input" value="<%= g.config.app_id || g.config.client_id || '' %>"></div>
<div class="form-group"><label class="form-label">Secret Key</label><input type="password" name="secret_key" class="form-input" value="<%= g.config.secret_key || g.config.client_secret || '' %>"></div>
<% } else if (g.name === 'manual_upi') { %>
<div class="form-group"><label class="form-label">UPI ID</label><input type="text" name="upi_id" class="form-input" value="<%= g.config.upi_id || '' %>"></div>
<div class="form-group"><label class="form-label">UPI Name</label><input type="text" name="upi_name" class="form-input" value="<%= g.config.upi_name || '' %>"></div>
<% } else if (g.name === 'manual_bank') { %>
<div class="form-row">
<div class="form-group"><label class="form-label">Bank Name</label><input type="text" name="bank_name" class="form-input" value="<%= g.config.bank_name || '' %>"></div>
<div class="form-group"><label class="form-label">Account Name</label><input type="text" name="account_name" class="form-input" value="<%= g.config.account_name || '' %>"></div>
</div>
<div class="form-group"><label class="form-label">Account Number</label><input type="text" name="account_number" class="form-input" value="<%= g.config.account_number || '' %>"></div>
<div class="form-row">
<div class="form-group"><label class="form-label">IFSC</label><input type="text" name="ifsc" class="form-input" value="<%= g.config.ifsc || '' %>"></div>
<div class="form-group"><label class="form-label">Branch</label><input type="text" name="branch" class="form-input" value="<%= g.config.branch || '' %>"></div>
</div>
<% } %>
<button class="btn btn-primary btn-sm"><i class="fas fa-save"></i> Save <%= g.name %></button>
</form></div>
<% }) %>
<%- include('../partials/admin-footer') %>
AGH_A_PAYSET_EOF

cat > views/admin/coupons.ejs <<'AGH_A_COUP_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Coupons</h1></div></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Create Coupon</h3>
<form method="POST" action="/admin/coupons"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Code</label><input type="text" name="code" class="form-input" required></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Type</label><select name="type" class="form-select"><option value="percent">% Percent</option><option value="fixed">Fixed Amount</option></select></div>
<div class="form-group"><label class="form-label">Value</label><input type="number" name="value" step="0.01" class="form-input" required></div>
</div>
<div class="form-row">
<div class="form-group"><label class="form-label">Min Total</label><input type="number" name="min_total" step="0.01" class="form-input" value="0"></div>
<div class="form-group"><label class="form-label">Max Uses (0=∞)</label><input type="number" name="max_uses" class="form-input" value="0"></div>
</div>
<div class="form-group"><label class="form-label">Expires At</label><input type="datetime-local" name="expires_at" class="form-input"></div>
<div class="form-checkbox mb-2"><input type="checkbox" name="active" checked><span>Active</span></div>
<button class="btn btn-primary"><i class="fas fa-plus"></i> Create</button></form>
</div>
<div class="card"><h3 class="card-title">All Coupons</h3>
<div class="table-wrap"><table class="table"><thead><tr><th>Code</th><th>Type</th><th>Value</th><th>Uses</th><th>Status</th><th></th></tr></thead><tbody>
<% coupons.forEach(c => { %><tr><td><strong><%= c.code %></strong></td><td><%= c.type %></td><td><%= c.value %></td><td><%= c.uses %><%= c.max_uses > 0 ? '/' + c.max_uses : '' %></td><td><span class="badge badge-<%= c.active ? 'success' : 'error' %>"><%= c.active ? 'Active' : 'Disabled' %></span></td><td><div class="actions"><form method="POST" action="/admin/coupons/<%= c.id %>/toggle" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-outline btn-sm"><i class="fas fa-power-off"></i></button></form><form method="POST" action="/admin/coupons/<%= c.id %>/delete" style="display:inline;"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm"><i class="fas fa-trash"></i></button></form></div></td></tr><% }) %>
</tbody></table></div>
</div>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_COUP_EOF

cat > views/admin/invoices.ejs <<'AGH_A_INV_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Invoices</h1></div></div>
<div class="table-wrap"><table class="table"><thead><tr><th>Invoice #</th><th>Order</th><th>Customer</th><th>Amount</th><th>Status</th><th>Issued</th></tr></thead><tbody>
<% invoices.forEach(i => { %><tr><td><strong><%= i.invoice_number %></strong></td><td><%= i.order_number %></td><td><%= i.customer %></td><td>$<%= i.amount.toFixed(2) %></td><td><span class="badge badge-<%= i.status === 'paid' ? 'success' : 'warning' %>"><%= i.status %></span></td><td><%= new Date(i.issued_at*1000).toLocaleDateString() %></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_INV_EOF

cat > views/admin/tickets.ejs <<'AGH_A_TKTS_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Tickets</h1></div></div>
<div class="table-wrap"><table class="table"><thead><tr><th>Ticket</th><th>Customer</th><th>Subject</th><th>Status</th><th>Priority</th><th></th></tr></thead><tbody>
<% tickets.forEach(t => { %><tr><td><%= t.ticket_number %></td><td><%= t.customer %></td><td><%= t.subject %></td><td><span class="badge badge-<%= t.status === 'open' ? 'warning' : t.status === 'closed' ? 'success' : 'info' %>"><%= t.status %></span></td><td><%= t.priority %></td><td><a href="/admin/tickets/<%= t.id %>" class="btn btn-outline btn-sm">Open</a></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_TKTS_EOF

cat > views/admin/ticket-details.ejs <<'AGH_A_TKTD_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1><%= ticket.subject %></h1><p><%= ticket.customer %> · <%= ticket.ticket_number %></p></div><a href="/admin/tickets" class="btn btn-outline">Back</a></div>
<% messages.forEach(m => { %><div class="card mb-2" style="<%= m.is_admin ? 'border-color:var(--primary);' : '' %>"><div style="display:flex;justify-content:space-between;margin-bottom:8px;"><strong><%= m.author || 'User' %><%= m.is_admin ? ' (Staff)' : '' %></strong><span class="text-muted" style="font-size:0.8rem;"><%= new Date(m.created_at*1000).toLocaleString() %></span></div><p style="white-space:pre-wrap;"><%= m.message %></p></div><% }) %>
<div class="card mt-3"><h3 class="card-title">Reply</h3>
<form method="POST" action="/admin/tickets/<%= ticket.id %>/reply"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><textarea name="message" class="form-textarea" required></textarea></div>
<div class="form-group"><label class="form-label">Set Status</label><select name="status" class="form-select"><option value="open">Open</option><option value="awaiting">Awaiting Customer</option><option value="closed">Closed</option></select></div>
<button class="btn btn-primary"><i class="fas fa-paper-plane"></i> Send Reply</button></form></div>
<%- include('../partials/admin-footer') %>
AGH_A_TKTD_EOF

cat > views/admin/announcements.ejs <<'AGH_A_ANN_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Announcements</h1></div></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Create Announcement</h3>
<form method="POST" action="/admin/announcements"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Title</label><input type="text" name="title" class="form-input" required></div>
<div class="form-group"><label class="form-label">Message</label><textarea name="message" class="form-textarea" required></textarea></div>
<div class="form-group"><label class="form-label">Type</label><select name="type" class="form-select"><option value="info">Info</option><option value="success">Success</option><option value="warning">Warning</option></select></div>
<div class="form-checkbox mb-2"><input type="checkbox" name="active" checked><span>Active</span></div>
<button class="btn btn-primary">Create</button></form>
</div>
<div class="card"><h3 class="card-title">All Announcements</h3>
<% announcements.forEach(a => { %><div style="padding:12px;border:1px solid var(--border);border-radius:8px;margin-bottom:8px;"><div style="display:flex;justify-content:space-between;"><strong><%= a.title %></strong><form method="POST" action="/admin/announcements/<%= a.id %>/delete"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm"><i class="fas fa-trash"></i></button></form></div><p class="text-muted" style="font-size:0.85rem;margin-top:4px;"><%= a.message %></p></div><% }) %>
</div></div>
<%- include('../partials/admin-footer') %>
AGH_A_ANN_EOF

cat > views/admin/notifications.ejs <<'AGH_A_NOT_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Notifications</h1></div></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Send Notification</h3>
<form method="POST" action="/admin/notifications"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">User ID (blank = all)</label><input type="number" name="user_id" class="form-input"></div>
<div class="form-group"><label class="form-label">Title</label><input type="text" name="title" class="form-input" required></div>
<div class="form-group"><label class="form-label">Message</label><textarea name="message" class="form-textarea"></textarea></div>
<div class="form-group"><label class="form-label">Link</label><input type="text" name="link" class="form-input"></div>
<button class="btn btn-primary">Send</button></form>
</div>
<div class="card"><h3 class="card-title">Recent</h3>
<% notifications.forEach(n => { %><div style="padding:10px;border-bottom:1px solid var(--border);"><strong><%= n.title %></strong><p class="text-muted" style="font-size:0.85rem;"><%= n.message %></p></div><% }) %>
</div></div>
<%- include('../partials/admin-footer') %>
AGH_A_NOT_EOF

cat > views/admin/themes.ejs <<'AGH_A_TH_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Themes</h1><p>Active: <strong><%= activeTheme %></strong></p></div></div>
<div class="grid-3">
<% themes.forEach(t => { %><div class="card">
<h3 style="margin-bottom:8px;"><%= t.name %> <% if (t.slug === activeTheme) { %><span class="badge badge-success">Active</span><% } %> <% if (!t.enabled) { %><span class="badge badge-error">Disabled</span><% } %></h3>
<div style="display:flex;gap:6px;margin-bottom:12px;">
<div style="width:24px;height:24px;border-radius:50%;background:<%= t.vars['--primary'] || '#8b5cf6' %>;"></div>
<div style="width:24px;height:24px;border-radius:50%;background:<%= t.vars['--bg'] || '#0a0a0f' %>;"></div>
<div style="width:24px;height:24px;border-radius:50%;background:<%= t.vars['--card'] || '#12121c' %>;"></div>
</div>
<div style="display:flex;gap:6px;">
<form method="POST" action="/admin/themes/activate"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><input type="hidden" name="slug" value="<%= t.slug %>"><button class="btn btn-primary btn-sm" <%= t.slug === activeTheme ? 'disabled' : '' %>><%= t.slug === activeTheme ? 'Active' : 'Activate' %></button></form>
<form method="POST" action="/admin/themes/<%= t.id %>/toggle"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-outline btn-sm"><%= t.enabled ? 'Disable' : 'Enable' %></button></form>
</div>
</div><% }) %>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_TH_EOF

cat > views/admin/animations.ejs <<'AGH_A_ANIM_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Animation Settings</h1></div></div>
<div class="card" style="max-width:600px;">
<form method="POST" action="/admin/animations"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-checkbox mb-2"><input type="checkbox" name="enabled" <%= enabled === '1' ? 'checked' : '' %>><span>Enable animations site-wide</span></div>
<div class="form-group"><label class="form-label">Intensity</label><select name="intensity" class="form-select"><option value="low" <%= intensity === 'low' ? 'selected' : '' %>>Low</option><option value="medium" <%= intensity === 'medium' ? 'selected' : '' %>>Medium</option><option value="high" <%= intensity === 'high' ? 'selected' : '' %>>High</option></select></div>
<button class="btn btn-primary">Save</button></form>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_ANIM_EOF

cat > views/admin/website-settings.ejs <<'AGH_A_WS_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Website Settings</h1></div></div>
<div class="card"><form method="POST" action="/admin/website-settings"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Site Name</label><input type="text" name="site_name" class="form-input" value="<%= settings.site_name || '' %>"></div>
<div class="form-group"><label class="form-label">Tagline</label><input type="text" name="site_tagline" class="form-input" value="<%= settings.site_tagline || '' %>"></div>
<div class="form-group"><label class="form-label">Description</label><textarea name="site_description" class="form-textarea"><%= settings.site_description || '' %></textarea></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Contact Email</label><input type="email" name="contact_email" class="form-input" value="<%= settings.contact_email || '' %>"></div>
<div class="form-group"><label class="form-label">Contact Phone</label><input type="text" name="contact_phone" class="form-input" value="<%= settings.contact_phone || '' %>"></div>
</div>
<div class="form-group"><label class="form-label">Discord Invite URL</label><input type="url" name="discord_invite" class="form-input" value="<%= settings.discord_invite || '' %>"></div>
<div class="form-row">
<div class="form-group"><label class="form-label">Tax Rate (%)</label><input type="number" name="tax_rate" step="0.01" class="form-input" value="<%= settings.tax_rate || '0' %>"></div>
<div class="form-group"><label class="form-label">Currency</label><input type="text" name="currency" class="form-input" value="<%= settings.currency || 'INR' %>"></div>
</div>
<button class="btn btn-primary"><i class="fas fa-save"></i> Save</button></form></div>
<%- include('../partials/admin-footer') %>
AGH_A_WS_EOF

cat > views/admin/seo-settings.ejs <<'AGH_A_SEO_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>SEO Settings</h1></div></div>
<div class="card"><form method="POST" action="/admin/seo-settings"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">SEO Title</label><input type="text" name="seo_title" class="form-input" value="<%= seo_title %>"></div>
<div class="form-group"><label class="form-label">SEO Description</label><textarea name="seo_description" class="form-textarea"><%= seo_description %></textarea></div>
<div class="form-group"><label class="form-label">SEO Keywords</label><input type="text" name="seo_keywords" class="form-input" value="<%= seo_keywords %>"></div>
<button class="btn btn-primary">Save</button></form></div>
<%- include('../partials/admin-footer') %>
AGH_A_SEO_EOF

cat > views/admin/email-settings.ejs <<'AGH_A_EMAIL_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Email Settings</h1></div></div>
<div class="card">
<div class="announcement-banner" style="background:rgba(59,130,246,0.1);border-color:rgba(59,130,246,0.3);margin-bottom:16px;"><i class="fas fa-info-circle"></i> SMTP credentials are in <code>.env</code>.</div>
<p><strong>SMTP Host:</strong> <%= smtp_host || 'not set' %></p><p><strong>SMTP Port:</strong> <%= smtp_port || 'not set' %></p><p><strong>SMTP User:</strong> <%= smtp_user || 'not set' %></p>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_EMAIL_EOF

cat > views/admin/security-settings.ejs <<'AGH_A_SEC_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Security Settings</h1></div></div>
<div class="card">
<p><strong>Environment:</strong> <span class="badge badge-info"><%= nodeEnv %></span></p>
<ul style="padding-left:20px;line-height:2;color:var(--muted);margin-top:16px;">
<li>✓ Helmet security headers</li><li>✓ CSRF on all forms</li><li>✓ Rate limiting (30 req/15min)</li><li>✓ Bcrypt hashing (12 rounds)</li><li>✓ HTTP-only secure cookies</li><li>✓ SQL injection protection</li><li>✓ File upload limit (5 MB)</li><li>✓ AES-256 encryption for gateway creds</li>
</ul></div>
<%- include('../partials/admin-footer') %>
AGH_A_SEC_EOF

cat > views/admin/navigation.ejs <<'AGH_A_NAV_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Navigation</h1></div></div>
<div class="card"><p class="text-muted">Navigation is auto-generated from categories.</p>
<div class="table-wrap mt-2"><table class="table"><thead><tr><th>Order</th><th>Name</th><th>Slug</th><th>Visible</th></tr></thead><tbody>
<% categories.forEach(c => { %><tr><td><%= c.sort_order %></td><td><%= c.name %></td><td><%= c.slug %></td><td><span class="badge badge-<%= c.visible ? 'success' : 'error' %>"><%= c.visible ? 'Yes' : 'No' %></span></td></tr><% }) %>
</tbody></table></div></div>
<%- include('../partials/admin-footer') %>
AGH_A_NAV_EOF

cat > views/admin/staff.ejs <<'AGH_A_STAFF_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Staff</h1><p>Admin & staff accounts</p></div></div>
<div class="grid-2 mb-3">
<div class="card"><h3 class="card-title">Add Staff</h3>
<form method="POST" action="/admin/staff"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-group"><label class="form-label">Name</label><input type="text" name="name" class="form-input" required></div>
<div class="form-group"><label class="form-label">Email</label><input type="email" name="email" class="form-input" required></div>
<div class="form-group"><label class="form-label">Password</label><input type="password" name="password" class="form-input" minlength="8" required></div>
<div class="form-group"><label class="form-label">Role</label><select name="role" class="form-select"><option value="staff">Staff</option><option value="admin">Admin</option></select></div>
<button class="btn btn-primary">Create</button></form>
</div>
<div class="card"><h3 class="card-title">Existing Staff</h3>
<div class="table-wrap"><table class="table"><thead><tr><th>Name</th><th>Email</th><th>Role</th><th></th></tr></thead><tbody>
<% staff.forEach(s => { %><tr><td><%= s.name %></td><td><%= s.email %></td><td><span class="badge badge-primary"><%= s.role %></span></td><td><form method="POST" action="/admin/staff/<%= s.id %>/delete"><input type="hidden" name="_csrf" value="<%= csrfToken %>"><button class="btn btn-danger btn-sm" data-confirm="Delete staff member?"><i class="fas fa-trash"></i></button></form></td></tr><% }) %>
</tbody></table></div>
</div></div>
<%- include('../partials/admin-footer') %>
AGH_A_STAFF_EOF

cat > views/admin/activity-logs.ejs <<'AGH_A_LOGS_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Activity Logs</h1></div></div>
<div class="table-wrap"><table class="table"><thead><tr><th>Time</th><th>User</th><th>Action</th><th>Details</th><th>IP</th></tr></thead><tbody>
<% logs.forEach(l => { %><tr><td><%= new Date(l.created_at*1000).toLocaleString() %></td><td><%= l.user_name || '—' %></td><td><span class="badge badge-info"><%= l.action %></span></td><td><%= l.details %></td><td><%= l.ip %></td></tr><% }) %>
</tbody></table></div>
<%- include('../partials/admin-footer') %>
AGH_A_LOGS_EOF

cat > views/admin/maintenance.ejs <<'AGH_A_MAINT_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Maintenance Mode</h1></div></div>
<div class="card" style="max-width:600px;">
<form method="POST" action="/admin/maintenance"><input type="hidden" name="_csrf" value="<%= csrfToken %>">
<div class="form-checkbox mb-2"><input type="checkbox" name="enabled" <%= enabled ? 'checked' : '' %>><span>Enable maintenance mode</span></div>
<p class="text-muted" style="font-size:0.85rem;">When enabled, only admins can access the customer site.</p>
<button class="btn btn-primary mt-2">Save</button></form>
</div>
<%- include('../partials/admin-footer') %>
AGH_A_MAINT_EOF

cat > views/admin/contact-messages.ejs <<'AGH_A_CONTACT_EOF'
<%- include('../partials/admin-header') %>
<div class="page-header"><div><h1>Contact Messages</h1></div></div>
<% messages.forEach(m => { %><div class="card mb-2"><div style="display:flex;justify-content:space-between;"><strong><%= m.name %> &lt;<%= m.email %>&gt;</strong><span class="text-muted" style="font-size:0.8rem;"><%= new Date(m.created_at*1000).toLocaleString() %></span></div><% if (m.subject) { %><p style="margin-top:4px;"><strong>Subject:</strong> <%= m.subject %></p><% } %><p class="text-muted mt-2" style="white-space:pre-wrap;"><%= m.message %></p></div><% }) %>
<%- include('../partials/admin-footer') %>
AGH_A_CONTACT_EOF
log "All admin views written"

# ============================================================
# 12. README (no nested fences — plain indented code)
# ============================================================
step "Writing README"
cat > README.md <<'AGH_README_EOF'
# AG TECH HOSTING

Complete production-ready hosting provider platform built with Node.js, Express, EJS, and SQLite3.

## Quick Start

    chmod +x setup.sh
    ./setup.sh
    npm start

## URLs

| Interface | URL |
|-----------|-----|
| Customer site | http://localhost:3000 |
| Admin panel | http://localhost:3000/admin/login |
| Customer login | http://localhost:3000/auth/login |

## Default Admin

- Email: see ADMIN_EMAIL in .env (default: admin@agtechhosting.com)
- Password: see ADMIN_PASSWORD in .env (default: ChangeMeNow!123)

Change this password immediately after first login.

## Features

- Premium customer store with animated homepage
- 13 hosting categories, 8 sample products
- Full cart, checkout, coupon system
- 7 payment gateways (Razorpay, Stripe, PayPal, Cashfree, PhonePe, Manual UPI, Manual Bank)
- Complete admin panel with dashboard, product/category/order/customer management
- Ticket system, invoices, notifications, activity logs
- 8 dynamic themes with live switching
- CSRF, Helmet, rate limiting, bcrypt, encrypted gateway credentials
- Responsive mobile design

## Configure Payments

Edit .env:

    PAYMENT_PROVIDER=razorpay
    RAZORPAY_KEY_ID=...
    RAZORPAY_KEY_SECRET=...

Or manage from /admin/payment-settings.

## Themes

Admin -> Themes -> Activate any of 8 built-in themes. Customers can select their own from /settings.

## Production

    npm install -g pm2
    pm2 start app.js --name agtech
    pm2 save && pm2 startup

Set NODE_ENV=production and COOKIE_SECURE=true (requires HTTPS).

## Rerunning Installer

Safe to re-run. Preserves existing .env (backs up to .env.bak) and database.sqlite.
AGH_README_EOF
log "README written"

# ============================================================
# 13. VALIDATION
# ============================================================
step "Validating project structure"
REQUIRED=("app.js" "package.json" ".env"
  "public/css/style.css" "public/css/admin.css"
  "public/js/main.js" "public/js/admin.js"
  "views/partials/header.ejs" "views/partials/footer.ejs"
  "views/partials/admin-header.ejs" "views/partials/admin-footer.ejs"
  "views/customer/index.ejs" "views/customer/login.ejs" "views/customer/register.ejs"
  "views/customer/dashboard.ejs" "views/customer/cart.ejs" "views/customer/checkout.ejs"
  "views/customer/product-details.ejs"
  "views/admin/login.ejs" "views/admin/dashboard.ejs" "views/admin/products.ejs" "views/admin/orders.ejs")
MISSING=0
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$f" ]; then warn "MISSING: $f"; MISSING=1; fi
done
[ "$MISSING" -eq 1 ] && die "Required files missing. Aborting."
log "All required files present"

# ============================================================
# 14. INSTALL DEPENDENCIES
# ============================================================
step "Installing npm dependencies (may take 1-2 minutes)"
if ! npm install --no-audit --no-fund; then
  err "npm install failed."
  warn "If better-sqlite3 build failed:"
  warn "  sudo apt-get install -y build-essential python3"
  warn "  npm install"
  exit 1
fi
log "Dependencies installed"

# ============================================================
# 15. INIT DATABASE
# ============================================================
step "Initializing SQLite database and seed data"
node -e "
require('dotenv').config();
const Database = require('better-sqlite3');
const dbPath = process.env.DATABASE_PATH || './database.sqlite';
const db = new Database(dbPath);
db.pragma('journal_mode = WAL');
console.log('[db] Initialized at', dbPath);
db.close();
" || die "Database init failed"
log "Database ready"

# ============================================================
# 16. HEALTH CHECK
# ============================================================
step "Running application health-check"
PORT_VAL=$(grep '^PORT=' .env | cut -d= -f2 || echo 3000)
node app.js > /tmp/agtech-startup.log 2>&1 &
APP_PID=$!
sleep 6
if kill -0 $APP_PID 2>/dev/null; then
  if command -v curl >/dev/null 2>&1; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT_VAL}/" || echo "000")
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then log "Server responded HTTP $CODE — OK"
    else warn "Server up but HTTP $CODE"; tail -15 /tmp/agtech-startup.log; fi
  else
    log "Server started OK (curl not available for HTTP test)"
  fi
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
else
  err "Server failed to start. Log:"
  cat /tmp/agtech-startup.log
  exit 1
fi

# ============================================================
# 17. FINAL OUTPUT
# ============================================================
ADMIN_EMAIL_V=$(grep '^ADMIN_EMAIL=' .env | cut -d= -f2)
PORT_VAL=$(grep '^PORT=' .env | cut -d= -f2)
DB_PATH=$(grep '^DATABASE_PATH=' .env | cut -d= -f2)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        AG TECH HOSTING — INSTALL COMPLETE           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Website URL:${NC}     http://localhost:${PORT_VAL}"
echo -e "  ${CYAN}Admin Panel:${NC}     http://localhost:${PORT_VAL}/admin/login"
echo -e "  ${CYAN}Admin Email:${NC}     ${ADMIN_EMAIL_V}"
echo -e "  ${CYAN}Project Dir:${NC}     ${PROJECT_DIR}"
echo -e "  ${CYAN}Database:${NC}        ${PROJECT_DIR}/${DB_PATH:-database.sqlite}"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Edit ${CYAN}.env${NC} and change ADMIN_PASSWORD"
echo -e "  2. Configure payment credentials in .env or /admin/payment-settings"
echo -e "  3. Start server:  ${CYAN}npm start${NC}"
echo -e "  4. Visit /admin/login and log in"
echo ""
echo -e "  ${YELLOW}⚠  Change default admin password immediately after first login.${NC}"
echo ""

# 🖨️ Windows Sharing Printer

Script PowerShell untuk manajemen printer jaringan di lingkungan sekolah — mendukung setup server, konfigurasi client, troubleshooting SMB, dan fix PrintNightmare secara otomatis.

---

## 📋 Daftar Isi

- [Fitur](#fitur)
- [Persyaratan](#persyaratan)
- [Cara Menjalankan](#cara-menjalankan)
- [Menu & Fungsi](#menu--fungsi)
- [Panduan Setup Printer Jaringan](#panduan-setup-printer-jaringan)
- [Troubleshooting](#troubleshooting)
- [Fix PrintNightmare](#fix-printnightmare)
- [Catatan Keamanan](#catatan-keamanan)

---

## Fitur

- **Setup SERVER otomatis** — Print Spooler, SMB, firewall, network profile, password protected sharing, share printer, semua dalam satu langkah
- **Setup CLIENT otomatis** — konfigurasi SMB client, firewall, test ping, test akses UNC, install printer (4 metode fallback)
- **Fix PrintNightmare** — menangani CVE-2021-1675 / CVE-2021-34527 yang memperketat kebijakan driver printer di Windows 10
- **Diagnostik lengkap** — laporan detail untuk teknisi: IP, subnet, gateway, DNS, MAC, services, firewall, SMB config, printer status, shared folders
- **Auto-elevate** — otomatis minta UAC Administrator saat dijalankan
- **4 metode fallback** saat connect printer (Add-Printer → WScript.Network → net use → rundll32 printui)

---

## Persyaratan

| Kebutuhan | Detail |
|---|---|
| OS | Windows 10 (semua edisi) |
| Hak akses | Administrator (script auto-elevate) |
| PowerShell | Versi 5.1 ke atas (sudah built-in di Win10) |
| Jaringan | Server dan client harus berada di subnet yang sama |
| Driver printer | Terinstall di PC server sebelum di-share |

---

## Cara Menjalankan

**Klik kanan → Run with PowerShell**

Atau jika ExecutionPolicy diperketat:

```powershell
powershell -ExecutionPolicy Bypass -File printer-manager.ps1
```

> Script akan otomatis meminta UAC Administrator jika belum dijalankan sebagai Admin.

---

## Menu & Fungsi

```
╔═══════════════════════════════════════════╗
║        WINDOWS SHARING PRINTER             ║
║        Windows 10  |  Full Support        ║
╚═══════════════════════════════════════════╝

── SETUP ──────────────────────────────────────
  1. Setup SERVER   (jalankan di PC yang punya printer)
  2. Setup CLIENT   (jalankan di PC yang mau pakai printer)

── MANAJEMEN PRINTER ──────────────────────────
  3. Share Printer    (cepat, server sudah siap)
  4. Connect Printer  (cepat, client sudah siap)
  5. List Printer
  6. Set Default Printer
  7. Hapus Printer

── ALAT TEKNISI ───────────────────────────────
  8. Diagnostik Lengkap (IP, SMB, firewall, dll)
  9. Fix PrintNightmare (CVE-2021-1675/34527)
```

### Menu 1 — Setup SERVER

Menjalankan konfigurasi lengkap secara berurutan:

1. Nyalakan & set Print Spooler ke Automatic
2. Ubah Network Profile dari Public → Private
3. Aktifkan firewall rules: File & Printer Sharing + Network Discovery
4. Nyalakan SMB Server (LanmanServer)
5. Matikan Password Protected Sharing
6. Aktifkan Network Discovery
7. Pilih printer dan set share name

Setelah selesai menampilkan: path share, nama komputer, dan semua IP aktif.

### Menu 2 — Setup CLIENT

1. Ubah Network Profile Public → Private
2. Aktifkan firewall rules
3. Nyalakan SMB Client (LanmanWorkstation)
4. Ping test ke server
5. Test akses UNC path
6. Jika gagal: tawarkan login dengan username/password server
7. Install printer (4 metode otomatis)

### Menu 8 — Diagnostik Lengkap

Laporan mencakup:

- **Identitas PC**: nama komputer, workgroup/domain, OS, build, arsitektur, RAM
- **Semua network adapter**: IP, subnet mask, gateway, DNS, MAC address, link speed, network profile
- **Services**: Spooler, LanmanServer, LanmanWorkstation, NetBIOS, Netlogon
- **Firewall**: status per profile (Domain/Private/Public), status per rule group
- **SMB config**: SMB1/SMB2 server & client, security signing
- **Detail printer**: nama, driver, port, share name, status
- **Shared folders**: semua share aktif via Get-SmbShare
- **Ping gateway**: test otomatis ke semua default gateway

### Menu 9 — Fix PrintNightmare

Sub-menu:
- `CEK STATUS` — tampilkan nilai registry saat ini + KB patch yang terinstall
- `FIX SERVER` — perbaiki registry di PC host printer
- `FIX CLIENT` — perbaiki registry di PC client
- `FIX KEDUANYA` — jalankan semua sekaligus

---

## Panduan Setup Printer Jaringan

### Langkah-langkah (urutan wajib)

```
[PC SERVER]
1. Install driver printer resmi (64-bit) dari website pabrik
2. Pastikan printer muncul normal tanpa warning
3. Jalankan printer-manager.ps1 → Menu 9 → Fix Server
4. Restart PC server
5. Jalankan printer-manager.ps1 → Menu 1 → Setup Server
6. Catat IP dan path share yang ditampilkan

[PC CLIENT]
7. Jalankan printer-manager.ps1 → Menu 9 → Fix Client
8. Restart PC client
9. Jalankan printer-manager.ps1 → Menu 2 → Setup Client
10. Masukkan IP server dan nama share dari langkah 6
```

### Informasi yang dibutuhkan client dari server

| Info | Cara mendapatkan |
|---|---|
| IP server | Menu 1 (ditampilkan otomatis) atau Menu 8 Diagnostik |
| Nama share | Ditentukan saat Menu 1 atau Menu 3 (default: `PRINTER_SEKOLAH`) |
| Path lengkap | `\\IP_SERVER\NAMA_SHARE` contoh: `\\192.168.1.10\PRINTER_SEKOLAH` |

---

## Troubleshooting

### Error: "Windows cannot connect to the printer"

Penyebab dan solusinya:

| Gejala | Penyebab | Solusi |
|---|---|---|
| Error `0x0000007e` | Driver tidak ada di client | Install driver printer di client |
| Error `0x00000709` | Nama printer terlalu panjang | Ganti share name yang lebih pendek |
| Error `Access is denied` | Password Protected Sharing aktif | Menu 1 Setup Server (matikan otomatis) |
| Path tidak bisa diakses | Network profile = Public | Menu 1/2 ubah ke Private otomatis |
| Ping OK tapi UNC gagal | Firewall blokir port 445 | Menu 1 aktifkan firewall rules |
| Driver gagal otomatis | PrintNightmare patch aktif | Menu 9 Fix PrintNightmare |

### Cek manual via PowerShell

```powershell
# Cek printer yang sudah di-share
Get-Printer | Where-Object { $_.Shared }

# Cek SMB server berjalan
Get-Service LanmanServer

# Cek network profile
Get-NetConnectionProfile

# Test akses path jaringan
Test-Path \\192.168.1.10\PRINTER_SEKOLAH

# Cek firewall printer sharing
Get-NetFirewallRule | Where-Object { $_.DisplayGroup -like "*Printer*" -and $_.Enabled }
```

### Epson L3210 — Catatan Khusus

Windows 10 tidak memiliki driver Epson built-in. Jika client gagal auto-install driver dari server:

1. Download **Drivers and Utilities Combo Package** dari [epson.co.id](https://epson.co.id) → Support → L3210 → Windows 10 64-bit
2. Install di **server dulu**, pastikan printer normal
3. Install yang sama di **client jika masih gagal**
4. Urutan install: jangan colok USB sebelum installer meminta

---

## Fix PrintNightmare

**PrintNightmare** (CVE-2021-1675 & CVE-2021-34527) adalah vulnerability pada Windows Print Spooler yang di-patch Microsoft pada pertengahan 2021. Patch tersebut memperketat kebijakan Point and Print sehingga sharing printer antar PC menjadi sulit.

### Registry yang dimodifikasi

| Key | Nilai | Tujuan |
|---|---|---|
| `PointAndPrint\RestrictDriverInstallationToAdministrators` | `0` | Client bisa install driver tanpa jadi Admin |
| `PointAndPrint\NoWarningNoElevationOnInstall` | `1` | Tidak muncul UAC saat connect printer |
| `PointAndPrint\UpdatePromptSettings` | `2` | Update driver tidak diblokir |
| `Control\Print\RpcAuthnLevelPrivacyEnabled` | `0` | Izinkan koneksi RPC printer lama |
| `PackagePointAndPrintOnly` | `0` | Tidak wajib signed package driver |
| `LanMan Print Services\AddPrinterDrivers` | `1` | Server boleh kirim driver ke client |

> **Catatan**: Fix ini melonggarkan kebijakan keamanan printer. Cocok untuk jaringan lokal sekolah yang terisolasi. Untuk jaringan dengan akses internet terbuka, pertimbangkan risiko keamanannya.

### KB patch terkait PrintNightmare

Script otomatis mendeteksi apakah patch berikut terinstall:
`KB5005033` `KB5005031` `KB5005010` `KB5004945` `KB5004237` `KB5004946` `KB5004244` `KB5004243`

---

## Catatan Keamanan

Script ini melonggarkan beberapa kebijakan keamanan Windows yang sengaja diperketat oleh Microsoft. Penggunaan direkomendasikan untuk:

- Jaringan lokal sekolah yang tidak terhubung langsung ke internet publik
- Lab komputer dengan topologi LAN tertutup
- Lingkungan yang dikontrol oleh admin/teknisi sekolah

Tidak disarankan untuk PC yang terhubung ke domain korporat atau jaringan dengan kebijakan keamanan tinggi tanpa konsultasi dengan admin jaringan.

---

## Lisensi

MIT License   
bebas digunakan, dimodifikasi, dan didistribusikan untuk keperluan pendidikan.

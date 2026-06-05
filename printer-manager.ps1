# ============================================================
#  printer-manager.ps1
#  School Printer Manager — Full Windows 10 Support
#  Requires: Run as Administrator
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Auto-elevate jika belum Administrator ───────────────────
function Assert-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ""
        Write-Host "  [!] Script harus dijalankan sebagai Administrator." -ForegroundColor Yellow
        Write-Host "      Mencoba elevasi otomatis..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell -Verb RunAs -ArgumentList $args
        exit
    }
}

Assert-Admin

# ── Helper: warna output ────────────────────────────────────
function Write-Success { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green  }
function Write-Fail    { param($msg) Write-Host "  [!]  $msg" -ForegroundColor Red    }
function Write-Info    { param($msg) Write-Host "  [i]  $msg" -ForegroundColor Cyan   }

# ── Helper: pilih printer dari daftar, return objek printer ─
function Select-Printer {
    param([string]$Prompt = "Pilih nomor printer")

    try {
        $printers = @(Get-Printer -ErrorAction Stop)
    } catch {
        Write-Fail "Gagal membaca daftar printer: $_"
        return $null
    }

    if ($printers.Count -eq 0) {
        Write-Info "Tidak ada printer terpasang."
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $shared = if ($printers[$i].Shared) { "[Shared]" } else { "" }
        $def    = if ($printers[$i].Default) { "[Default]" } else { "" }
        Write-Host ("  {0,2}. {1} {2} {3}" -f ($i + 1), $printers[$i].Name, $shared, $def)
    }
    Write-Host ""

    $input = Read-Host $Prompt
    if (-not ($input -match '^\d+$')) {
        Write-Fail "Input tidak valid."
        return $null
    }
    $idx = [int]$input - 1
    if ($idx -lt 0 -or $idx -ge $printers.Count) {
        Write-Fail "Nomor di luar range."
        return $null
    }
    return $printers[$idx]
}

# ── Helper: set default printer via COM (Windows 10 compatible)
function Set-DefaultPrinterWin10 {
    param([string]$PrinterName)
    try {
        # Metode 1: WScript.Network (paling reliable di Win10)
        $net = New-Object -ComObject WScript.Network
        $net.SetDefaultPrinter($PrinterName)
        return $true
    } catch {
        try {
            # Metode 2: Registry fallback
            $regPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"
            Set-ItemProperty -Path $regPath -Name "Device" -Value "$PrinterName,winspool,Ne00:" -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
}

# ── Helper: aktifkan File & Printer Sharing di firewall ─────
function Enable-PrinterFirewall {
    try {
        netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
        netsh advfirewall firewall set rule group="Printer Sharing"          new enable=Yes 2>$null | Out-Null
    } catch { <# diabaikan #> }
}

# ── Helper: perbaiki network profile Public → Private (Win10) ─
function Set-NetworkProfilePrivate {
    try {
        $profiles = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
        foreach ($p in $profiles) {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
            Write-Info "Network profile '$($p.Name)' diubah: Public → Private"
        }
    } catch { }
}

# ── Helper: simpan credentials server ke Credential Manager ──
function Save-ServerCredential {
    param([string]$Server, [string]$Username, [string]$Password)
    try {
        # Hapus dulu kalau sudah ada
        cmdkey /delete:"$Server" 2>$null | Out-Null
        cmdkey /add:"$Server" /user:"$Username" /pass:"$Password" | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ── Helper: connect printer — 4 metode untuk Win10 ───────────
function Connect-NetworkPrinter {
    param([string]$UNCPath, [string]$Server)

    # Metode 1: Add-Printer (butuh driver match)
    try {
        Add-Printer -ConnectionName $UNCPath -ErrorAction Stop
        return $true
    } catch { }

    # Metode 2: WScript.Network (lebih toleran terhadap driver)
    try {
        $net = New-Object -ComObject WScript.Network
        $net.AddWindowsPrinterConnection($UNCPath)
        return $true
    } catch { }

    # Metode 3: net use dulu untuk autentikasi, lalu Add-Printer
    try {
        net use "\\$Server" /persistent:no 2>$null | Out-Null
        Add-Printer -ConnectionName $UNCPath -ErrorAction Stop
        return $true
    } catch { }

    # Metode 4: rundll32 printui
    try {
        $proc = Start-Process -FilePath "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /in /n `"$UNCPath`"" `
            -Wait -PassThru
        if ($proc.ExitCode -eq 0) { return $true }
    } catch { }

    return $false
}

# ── Menu utama ───────────────────────────────────────────────
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host "        SCHOOL PRINTER MANAGER"           -ForegroundColor Cyan
    Write-Host "        Windows 10 Edition by irfnrdh"               -ForegroundColor DarkCyan
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Share Printer (Server/Host)"
    Write-Host "  2. Connect Printer (Client)"
    Write-Host "  3. List Semua Printer"
    Write-Host "  4. Set Default Printer"
    Write-Host "  5. Hapus Printer"
    Write-Host "  6. Info IP Komputer Ini"
    Write-Host "  0. Keluar"
    Write-Host ""
}

# ── Loop utama ───────────────────────────────────────────────
$running = $true

while ($running) {

    Show-Menu
    $choice = Read-Host "  Pilih Menu"

    switch ($choice) {

        # ── 1. Share Printer ──────────────────────────────────
        "1" {
            $printer = Select-Printer "Pilih printer yang akan di-share"
            if ($null -eq $printer) { pause; break }

            $shareName = Read-Host "Nama Share (kosongkan = PRINTER_SEKOLAH)"
            if ([string]::IsNullOrWhiteSpace($shareName)) {
                $shareName = "PRINTER_SEKOLAH"
            }

            # Validasi: nama share tidak boleh ada spasi / karakter khusus
            $shareName = $shareName -replace '[^\w\-]', '_'

            try {
                Enable-PrinterFirewall

                # Pastikan Print Spooler jalan
                $spooler = Get-Service -Name Spooler
                if ($spooler.Status -ne 'Running') {
                    Start-Service Spooler
                    Write-Info "Print Spooler dinyalakan."
                }

                Set-Printer -Name $printer.Name -Shared $true -ShareName $shareName -ErrorAction Stop

                Write-Host ""
                Write-Success "Printer berhasil di-share!"
                Write-Host ""
                Write-Host "  Path jaringan  : " -NoNewline
                Write-Host "\\$env:COMPUTERNAME\$shareName" -ForegroundColor Yellow
                Write-Host "  Nama Komputer  : $env:COMPUTERNAME"
                Write-Host ""

                # Tampilkan IP aktif untuk memudahkan client
                $ips = Get-NetIPAddress -AddressFamily IPv4 |
                       Where-Object { $_.IPAddress -notmatch '^127\.' } |
                       Select-Object -ExpandProperty IPAddress
                Write-Host "  IP Komputer    : " -NoNewline
                Write-Host ($ips -join ", ") -ForegroundColor Yellow
                Write-Host ""
                Write-Info "Berikan salah satu IP di atas ke komputer client."

            } catch {
                Write-Fail "Gagal share printer: $_"
            }

            pause
        }

        # ── 2. Connect Printer ────────────────────────────────
        "2" {
            Write-Host ""
            $server = Read-Host "  IP atau Nama Server (contoh: 192.168.1.10)"
            $share  = Read-Host "  Nama Share (contoh: PRINTER_SEKOLAH)"

            if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($share)) {
                Write-Fail "Server dan nama share tidak boleh kosong."
                pause; break
            }

            $unc = "\\$server\$share"

            # ── STEP 1: Aktifkan firewall client ──────────────
            Write-Info "[1/5] Mengaktifkan File & Printer Sharing di client..."
            Enable-PrinterFirewall

            # ── STEP 2: Set network profile ke Private ────────
            Write-Info "[2/5] Memastikan network profile = Private..."
            Set-NetworkProfilePrivate

            # ── STEP 3: Enable SMB client (sering mati di Win10)
            Write-Info "[3/5] Mengaktifkan SMB client..."
            try {
                sc.exe config lanmanworkstation start= auto | Out-Null
                Start-Service lanmanworkstation -ErrorAction SilentlyContinue
            } catch { }

            # ── STEP 4: Test ping ke server ───────────────────
            Write-Info "[4/5] Ping ke server $server ..."
            $ping = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
            if (-not $ping) {
                Write-Fail "Server $server tidak merespons ping."
                Write-Host ""
                Write-Host "  Kemungkinan penyebab:" -ForegroundColor Yellow
                Write-Host "    - Komputer server mati atau IP salah"
                Write-Host "    - Beda network / VLAN"
                Write-Host "    - Firewall server memblokir ICMP"
                Write-Host ""
                Write-Host "  Tetap lanjut coba connect? (y/N) " -NoNewline
                $lanjut = Read-Host
                if ($lanjut -notmatch '^[yY]$') { pause; break }
            }

            # ── STEP 5: Cek akses UNC path ────────────────────
            Write-Info "[5/5] Mengakses $unc ..."
            $reachable = Test-Path $unc -ErrorAction SilentlyContinue

            if (-not $reachable) {
                Write-Host ""
                Write-Host "  Path $unc tidak dapat diakses." -ForegroundColor Red
                Write-Host ""
                Write-Host "  Kemungkinan penyebab & solusi:" -ForegroundColor Yellow
                Write-Host "    [A] Password Protected Sharing aktif di server"
                Write-Host "        → Masukkan username/password server di bawah"
                Write-Host "    [B] Nama share salah"
                Write-Host "        → Cek ulang nama share di komputer server (Menu 1)"
                Write-Host "    [C] Firewall server memblokir port 445"
                Write-Host "        → Jalankan script ini sebagai Admin di server"
                Write-Host ""
                $tryAuth = Read-Host "  Coba dengan username/password server? (y/N)"

                if ($tryAuth -match '^[yY]$') {
                    $user = Read-Host "  Username server (contoh: Administrator)"
                    $pass = Read-Host "  Password server" -AsSecureString
                    $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
                    )

                    # Simpan credentials ke Credential Manager
                    Save-ServerCredential -Server $server -Username $user -Password $plainPass | Out-Null

                    # net use dengan credentials
                    Write-Info "Autentikasi ke \\$server ..."
                    $netUse = net use "\\$server" /user:"$user" "$plainPass" /persistent:no 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Fail "Autentikasi gagal: $netUse"
                        Write-Info "Pastikan username dan password benar."
                        pause; break
                    }
                    Write-Success "Autentikasi berhasil."

                    # Cek ulang akses setelah auth
                    $reachable = Test-Path $unc -ErrorAction SilentlyContinue
                    if (-not $reachable) {
                        Write-Fail "Masih tidak bisa akses $unc setelah autentikasi."
                        Write-Info "Cek nama share di server: pastikan tidak ada spasi atau karakter aneh."
                        pause; break
                    }
                } else {
                    pause; break
                }
            }

            # ── Connect printer ───────────────────────────────
            Write-Host ""
            Write-Info "Menambahkan printer..."
            if (Connect-NetworkPrinter -UNCPath $unc -Server $server) {
                Write-Host ""
                Write-Success "Printer berhasil ditambahkan: $unc"
                Write-Info "Cek di: Settings > Printers & scanners"
            } else {
                Write-Host ""
                Write-Fail "Gagal menambahkan printer otomatis."
                Write-Host ""
                Write-Host "  Coba manual:" -ForegroundColor Yellow
                Write-Host "    1. Buka File Explorer"
                Write-Host "    2. Ketik di address bar: \\$server"
                Write-Host "    3. Double-click printer '$share'"
                Write-Host "    4. Windows akan install driver otomatis"
            }

            pause
        }

        # ── 3. List Printer ───────────────────────────────────
        "3" {
            Write-Host ""
            try {
                $printers = @(Get-Printer -ErrorAction Stop)
                if ($printers.Count -eq 0) {
                    Write-Info "Tidak ada printer terpasang."
                } else {
                    $printers | Format-Table `
                        @{L="No" ;E={[array]::IndexOf($printers,$_)+1}; W=4},
                        @{L="Nama Printer"   ;E={$_.Name}          ; W=40},
                        @{L="Shared"         ;E={$_.Shared}        ; W=8},
                        @{L="Default"        ;E={$_.Default}       ; W=8},
                        @{L="Tipe"           ;E={$_.Type}          ; W=10},
                        @{L="Status"         ;E={$_.PrinterStatus} ; W=12} `
                        -AutoSize
                }
            } catch {
                Write-Fail "Gagal membaca printer: $_"
            }

            pause
        }

        # ── 4. Set Default Printer ────────────────────────────
        "4" {
            $printer = Select-Printer "Pilih printer yang dijadikan default"
            if ($null -eq $printer) { pause; break }

            # Nonaktifkan "Let Windows manage default printer" di Win10
            try {
                $regPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"
                Set-ItemProperty -Path $regPath `
                    -Name "LegacyDefaultPrinterMode" -Value 1 -Type DWord -Force
            } catch { }

            if (Set-DefaultPrinterWin10 -PrinterName $printer.Name) {
                Write-Success "Default printer diubah ke: $($printer.Name)"
            } else {
                Write-Fail "Gagal mengubah default printer."
                Write-Info "Coba ubah manual: Settings > Printers & scanners"
            }

            pause
        }

        # ── 5. Hapus Printer ──────────────────────────────────
        "5" {
            $printer = Select-Printer "Pilih printer yang akan dihapus"
            if ($null -eq $printer) { pause; break }

            Write-Host ""
            $confirm = Read-Host "  Yakin hapus '$($printer.Name)'? (y/N)"
            if ($confirm -notmatch '^[yY]$') {
                Write-Info "Dibatalkan."
                pause; break
            }

            try {
                Remove-Printer -Name $printer.Name -ErrorAction Stop
                Write-Success "Printer '$($printer.Name)' berhasil dihapus."
            } catch {
                # Fallback: printui untuk printer yang stubborn
                try {
                    Start-Process "rundll32.exe" `
                        -ArgumentList "printui.dll,PrintUIEntry /dl /n `"$($printer.Name)`"" `
                        -Wait
                    Write-Success "Printer dihapus (via printui)."
                } catch {
                    Write-Fail "Gagal menghapus printer: $_"
                }
            }

            pause
        }

        # ── 6. Info IP ────────────────────────────────────────
        "6" {
            Write-Host ""
            Write-Host "  Nama Komputer : $env:COMPUTERNAME" -ForegroundColor Cyan
            Write-Host ""

            try {
                Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notmatch '^127\.' } |
                ForEach-Object {
                    $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
                    Write-Host ("  [{0}] {1}" -f $adapter.Name, $_.IPAddress) -ForegroundColor Yellow
                }
            } catch {
                # Fallback lama untuk Win10 yang tidak punya Get-NetIPAddress
                ipconfig | Select-String "IPv4"
            }

            Write-Host ""
            Write-Info "Gunakan IP di atas saat connect dari komputer client."
            pause
        }

        # ── 0. Keluar ─────────────────────────────────────────
        "0" {
            $running = $false
        }

        default {
            Write-Fail "Pilihan tidak valid."
            Start-Sleep -Seconds 1
        }
    }
}

Write-Host ""
Write-Host "  Sampai jumpa!" -ForegroundColor Cyan
Write-Host ""

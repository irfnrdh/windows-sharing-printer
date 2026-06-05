\\KEMBAR-PHOTO-PC-01-SERVER\F4_PANJANG



# ============================================================
#  printer-manager.ps1
#  School Printer Manager — Full Windows 10 Support
#  Requires: Run as Administrator
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

# ── Auto-elevate jika belum Administrator ───────────────────
function Assert-Admin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ""
        Write-Host "  [!] Script harus dijalankan sebagai Administrator." -ForegroundColor Yellow
        Write-Host "      Mencoba elevasi otomatis..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        $psargs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell -Verb RunAs -ArgumentList $psargs
        exit
    }
}

Assert-Admin

# ── Helper: warna output ────────────────────────────────────
function Write-OK   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "  [!]  $msg" -ForegroundColor Red   }
function Write-Info { param($msg) Write-Host "  [i]  $msg" -ForegroundColor Cyan  }

# ── Helper: pause tanpa error ────────────────────────────────
function Pause-Screen {
    Write-Host ""
    Write-Host "  Tekan Enter untuk kembali ke menu..." -ForegroundColor DarkGray -NoNewline
    $null = Read-Host
}

# ── Helper: pilih printer dari daftar ───────────────────────
# Return: objek printer, atau $null kalau gagal/batal
function Select-Printer {
    param([string]$Prompt = "Pilih nomor printer")

    $printers = @(Get-Printer 2>$null)

    if ($printers.Count -eq 0) {
        Write-Info "Tidak ada printer terpasang."
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $shared = if ($printers[$i].Shared)  { "[Shared]"  } else { "" }
        $def    = if ($printers[$i].Default) { "[Default]" } else { "" }
        Write-Host ("  {0,2}. {1} {2} {3}" -f ($i+1), $printers[$i].Name, $shared, $def)
    }
    Write-Host ""

    $raw = Read-Host $Prompt
    if ($raw -notmatch '^\d+$') {
        Write-Fail "Input tidak valid."
        return $null
    }
    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $printers.Count) {
        Write-Fail "Nomor di luar range."
        return $null
    }
    return $printers[$idx]
}

# ── Helper: set default printer (Win10 compatible) ──────────
function Set-DefaultPrinterWin10 {
    param([string]$PrinterName)
    # Metode 1: WScript.Network
    try {
        $net = New-Object -ComObject WScript.Network
        $net.SetDefaultPrinter($PrinterName)
        return $true
    } catch { }
    # Metode 2: Registry
    try {
        $reg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"
        Set-ItemProperty -Path $reg -Name "Device" -Value "$PrinterName,winspool,Ne00:" -Force
        return $true
    } catch { }
    return $false
}

# ── Helper: aktifkan firewall printer sharing ────────────────
function Enable-PrinterFirewall {
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes 2>$null | Out-Null
    netsh advfirewall firewall set rule group="Printer Sharing"          new enable=Yes 2>$null | Out-Null
}

# ── Helper: network profile Public → Private ─────────────────
function Set-NetworkProfilePrivate {
    try {
        $profiles = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
        foreach ($p in $profiles) {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
            Write-Info "Network profile '$($p.Name)': Public → Private"
        }
    } catch { }
}

# ── Helper: connect printer (4 metode fallback) ──────────────
function Connect-NetworkPrinter {
    param([string]$UNC, [string]$Server)

    # Metode 1: Add-Printer cmdlet
    try { Add-Printer -ConnectionName $UNC -ErrorAction Stop; return $true } catch { }

    # Metode 2: WScript.Network
    try {
        $net = New-Object -ComObject WScript.Network
        $net.AddWindowsPrinterConnection($UNC)
        return $true
    } catch { }

    # Metode 3: net use lalu Add-Printer
    try {
        net use "\\$Server" /persistent:no 2>$null | Out-Null
        Add-Printer -ConnectionName $UNC -ErrorAction Stop
        return $true
    } catch { }

    # Metode 4: rundll32 printui
    try {
        $p = Start-Process "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry /in /n `"$UNC`"" -Wait -PassThru
        if ($p.ExitCode -eq 0) { return $true }
    } catch { }

    return $false
}

# ── Helper: simpan credentials ke Credential Manager ────────
function Save-Credential {
    param([string]$Server, [string]$User, [string]$Pass)
    cmdkey /delete:"$Server"              2>$null | Out-Null
    cmdkey /add:"$Server" /user:"$User" /pass:"$Pass" 2>$null | Out-Null
}

# ── Menu utama ───────────────────────────────────────────────
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor Cyan
    Write-Host "        SCHOOL PRINTER MANAGER"            -ForegroundColor Cyan
    Write-Host "        Windows 10 Edition"                -ForegroundColor DarkCyan
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

# ── Fungsi per menu (masing-masing fungsi, tidak pakai break) ─

function Menu-SharePrinter {
    $printer = Select-Printer "Pilih printer yang akan di-share"
    if ($null -eq $printer) { Pause-Screen; return }

    $shareName = Read-Host "Nama Share (kosongkan = PRINTER_SEKOLAH)"
    if ([string]::IsNullOrWhiteSpace($shareName)) { $shareName = "PRINTER_SEKOLAH" }
    $shareName = $shareName -replace '[^\w\-]', '_'

    Enable-PrinterFirewall

    # Pastikan Print Spooler jalan
    $spooler = Get-Service -Name Spooler 2>$null
    if ($spooler -and $spooler.Status -ne 'Running') {
        Start-Service Spooler 2>$null
        Write-Info "Print Spooler dinyalakan."
    }

    # Set network profile ke Private supaya sharing aktif
    Set-NetworkProfilePrivate

    $ok = $false
    try {
        Set-Printer -Name $printer.Name -Shared $true -ShareName $shareName -ErrorAction Stop
        $ok = $true
    } catch {
        Write-Fail "Gagal share printer: $_"
    }

    if ($ok) {
        Write-Host ""
        Write-OK "Printer berhasil di-share!"
        Write-Host ""
        Write-Host "  Path jaringan : " -NoNewline
        Write-Host "\\$env:COMPUTERNAME\$shareName" -ForegroundColor Yellow
        Write-Host ""
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 2>$null |
                 Where-Object { $_.IPAddress -notmatch '^127\.' } |
                 Select-Object -ExpandProperty IPAddress)
        if ($ips.Count -gt 0) {
            Write-Host "  IP Server     : " -NoNewline
            Write-Host ($ips -join ", ") -ForegroundColor Yellow
        }
        Write-Info "Berikan IP di atas ke komputer client."
    }

    Pause-Screen
}

function Menu-ConnectPrinter {
    Write-Host ""
    $server = Read-Host "  IP atau Nama Server (contoh: 192.168.1.10)"
    $share  = Read-Host "  Nama Share (contoh: PRINTER_SEKOLAH)"

    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($share)) {
        Write-Fail "Server dan nama share tidak boleh kosong."
        Pause-Screen; return
    }

    $unc = "\\$server\$share"

    Write-Info "[1/5] Mengaktifkan firewall client..."
    Enable-PrinterFirewall

    Write-Info "[2/5] Set network profile ke Private..."
    Set-NetworkProfilePrivate

    Write-Info "[3/5] Mengaktifkan SMB client..."
    sc.exe config lanmanworkstation start= auto 2>$null | Out-Null
    Start-Service lanmanworkstation 2>$null

    Write-Info "[4/5] Ping ke $server ..."
    $ping = Test-Connection -ComputerName $server -Count 1 -Quiet 2>$null
    if (-not $ping) {
        Write-Fail "Server tidak merespons ping."
        Write-Host "  (Bisa jadi firewall server blokir ICMP — tetap lanjut coba)" -ForegroundColor DarkYellow
    }

    Write-Info "[5/5] Cek akses $unc ..."
    $reachable = Test-Path $unc 2>$null

    if (-not $reachable) {
        Write-Host ""
        Write-Fail "Path $unc tidak bisa diakses."
        Write-Host ""
        Write-Host "  Kemungkinan penyebab:" -ForegroundColor Yellow
        Write-Host "    [A] Password Protected Sharing aktif di server"
        Write-Host "    [B] Nama share salah (cek di server: Menu 1)"
        Write-Host "    [C] Firewall server blokir port 445"
        Write-Host ""

        $tryAuth = Read-Host "  Coba login dengan username/password server? (y/N)"
        if ($tryAuth -match '^[yY]$') {
            $user = Read-Host "  Username (contoh: Administrator)"
            $secPass = Read-Host "  Password" -AsSecureString
            $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
            )
            Save-Credential -Server $server -User $user -Pass $plainPass

            Write-Info "Autentikasi ke \\$server ..."
            net use "\\$server" /user:"$user" "$plainPass" /persistent:no 2>&1 | Out-Null

            $reachable = Test-Path $unc 2>$null
            if (-not $reachable) {
                Write-Fail "Masih tidak bisa akses setelah login."
                Write-Info "Cek nama share dan pastikan Password Protected Sharing dimatikan di server."
                Pause-Screen; return
            }
            Write-OK "Autentikasi berhasil."
        } else {
            Pause-Screen; return
        }
    }

    Write-Host ""
    Write-Info "Menambahkan printer..."
    if (Connect-NetworkPrinter -UNC $unc -Server $server) {
        Write-Host ""
        Write-OK "Printer berhasil ditambahkan!"
        Write-Info "Cek di: Settings > Printers & scanners"
    } else {
        Write-Host ""
        Write-Fail "Gagal otomatis. Coba manual:"
        Write-Host "    1. Buka File Explorer"
        Write-Host "    2. Address bar ketik: \\$server"
        Write-Host "    3. Double-click printer '$share'"
    }

    Pause-Screen
}

function Menu-ListPrinter {
    Write-Host ""
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) {
        Write-Info "Tidak ada printer terpasang."
    } else {
        $printers | Format-Table `
            @{L="No"          ; E={ [array]::IndexOf($printers,$_)+1 }; W=4  },
            @{L="Nama Printer"; E={ $_.Name }                          ; W=40 },
            @{L="Shared"      ; E={ $_.Shared }                        ; W=8  },
            @{L="Default"     ; E={ $_.Default }                       ; W=8  },
            @{L="Status"      ; E={ $_.PrinterStatus }                 ; W=12 } `
            -AutoSize
    }
    Pause-Screen
}

function Menu-SetDefault {
    $printer = Select-Printer "Pilih printer yang dijadikan default"
    if ($null -eq $printer) { Pause-Screen; return }

    # Matikan "Let Windows manage default printer"
    try {
        $reg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"
        Set-ItemProperty -Path $reg -Name "LegacyDefaultPrinterMode" -Value 1 -Type DWord -Force
    } catch { }

    if (Set-DefaultPrinterWin10 -PrinterName $printer.Name) {
        Write-OK "Default printer: $($printer.Name)"
    } else {
        Write-Fail "Gagal. Ubah manual: Settings > Printers & scanners"
    }
    Pause-Screen
}

function Menu-HapusPrinter {
    $printer = Select-Printer "Pilih printer yang akan dihapus"
    if ($null -eq $printer) { Pause-Screen; return }

    Write-Host ""
    $confirm = Read-Host "  Yakin hapus '$($printer.Name)'? (y/N)"
    if ($confirm -notmatch '^[yY]$') {
        Write-Info "Dibatalkan."
        Pause-Screen; return
    }

    $removed = $false
    try {
        Remove-Printer -Name $printer.Name -ErrorAction Stop
        $removed = $true
    } catch { }

    if (-not $removed) {
        try {
            Start-Process "rundll32.exe" `
                -ArgumentList "printui.dll,PrintUIEntry /dl /n `"$($printer.Name)`"" -Wait
            $removed = $true
        } catch { }
    }

    if ($removed) { Write-OK "Printer '$($printer.Name)' dihapus." }
    else          { Write-Fail "Gagal menghapus printer." }

    Pause-Screen
}

function Menu-InfoIP {
    Write-Host ""
    Write-Host "  Nama Komputer : $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host ""
    try {
        Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^127\.' } |
        ForEach-Object {
            $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex 2>$null
            $nama = if ($adapter) { $adapter.Name } else { "?" }
            Write-Host ("  [{0}]  {1}" -f $nama, $_.IPAddress) -ForegroundColor Yellow
        }
    } catch {
        ipconfig 2>$null | Select-String "IPv4"
    }
    Write-Host ""
    Write-Info "Gunakan IP ini saat client connect."
    Pause-Screen
}

# ── Loop utama — TANPA break di dalam switch ─────────────────
$running = $true

while ($running) {
    Show-Menu
    $choice = Read-Host "  Pilih Menu"

    switch ($choice) {
        "1"     { Menu-SharePrinter   }
        "2"     { Menu-ConnectPrinter }
        "3"     { Menu-ListPrinter    }
        "4"     { Menu-SetDefault     }
        "5"     { Menu-HapusPrinter   }
        "6"     { Menu-InfoIP         }
        "0"     { $running = $false   }
        default { Write-Fail "Pilihan tidak valid."; Start-Sleep -Seconds 1 }
    }
}

Write-Host ""
Write-Host "  Sampai jumpa!" -ForegroundColor Cyan
Write-Host ""

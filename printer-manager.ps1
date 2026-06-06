# ================================================================
#  printer-manager.ps1  |  Windows Sharing Printer  |  Win10 Pro
#  Untuk teknisi — setup lengkap SMB + sharing + diagnostik
# ================================================================

# ── Elevasi Admin ────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal]
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $scriptPath = if ($PSCommandPath) { $PSCommandPath }
                  elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
                  else { $null }

    if ($scriptPath) {
        Start-Process powershell.exe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    } else {
        # Dipanggil dari pipe / ISE — minta user re-run manual
        Write-Host "Jalankan script ini sebagai Administrator." -ForegroundColor Red
        Read-Host "Tekan Enter untuk keluar"
    }
    exit
}

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ================================================================
#  HELPER OUTPUT
# ================================================================
function OK   { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green  }
function FAIL { param($m) Write-Host "  [!]   $m" -ForegroundColor Red    }
function INFO { param($m) Write-Host "  [i]   $m" -ForegroundColor Cyan   }
function HEAD { param($m) Write-Host "`n  ── $m ──" -ForegroundColor Yellow }
function LINE { Write-Host "  " + ("─" * 50) -ForegroundColor DarkGray }
function WAIT {
    Write-Host ""
    Write-Host "  Tekan Enter untuk lanjut..." -ForegroundColor DarkGray -NoNewline
    $null = Read-Host
}

# ================================================================
#  HELPER: GET SERVICE STATUS
# ================================================================
function Get-SvcStatus { param($n)
    $s = Get-Service $n 2>$null
    if (-not $s) { return "Tidak ada" }
    return $s.Status
}

# ================================================================
#  HELPER: CEK FIREWALL RULE
# ================================================================
function Get-FWRuleStatus { param($group)
    $rules = Get-NetFirewallRule 2>$null |
             Where-Object { $_.DisplayGroup -like "*$group*" -and $_.Enabled -eq $true }
    if ($rules) { return "Aktif" } else { return "Nonaktif" }
}

# ================================================================
#  HELPER: PASSWORD PROTECTED SHARING STATUS
# ================================================================
function Get-PPSStatus {
    try {
        $val = Get-ItemProperty `
            "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
            -Name "restrictnullsessaccess" 2>$null
        # Cara lain: cek via reg SmbServerConfiguration
        $smb = Get-SmbServerConfiguration 2>$null
        if ($smb) {
            if ($smb.RequireSecuritySignature) { return "Aktif" }
        }
    } catch { }
    # Cek registry sharing mode
    $reg = Get-ItemProperty `
        "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
        -Name "everyoneincludesanonymous" 2>$null
    return "Tidak diketahui"
}

# ================================================================
#  A. SETUP SERVER — konfigurasi semua yang diperlukan di PC server
# ================================================================
function Setup-Server {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║       SETUP SERVER (PC yang punya        ║" -ForegroundColor Green
    Write-Host "  ║       printer / host printer)            ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green

    HEAD "STEP 1 — Print Spooler"
    $spooler = Get-Service -Name Spooler 2>$null
    if ($spooler.Status -ne 'Running') {
        Set-Service Spooler -StartupType Automatic
        Start-Service Spooler
        OK "Print Spooler dinyalakan & set Automatic"
    } else {
        OK "Print Spooler sudah Running"
    }

    HEAD "STEP 2 — Network Profile → Private"
    $changed = 0
    Get-NetConnectionProfile 2>$null |
    Where-Object { $_.NetworkCategory -eq 'Public' } |
    ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
        OK "[$($_.Name)] diubah Public → Private"
        $changed++
    }
    if ($changed -eq 0) { OK "Semua profile sudah Private / Domain" }

    HEAD "STEP 3 — Firewall: File & Printer Sharing"
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes 2>$null | Out-Null
    netsh advfirewall firewall set rule group="Network Discovery"         new enable=Yes 2>$null | Out-Null
    OK "Firewall rules diaktifkan"

    HEAD "STEP 4 — SMB Server (LanmanServer)"
    Set-Service LanmanServer -StartupType Automatic 2>$null
    Start-Service LanmanServer 2>$null
    OK "SMB Server service: Running"

    HEAD "STEP 5 — Matikan Password Protected Sharing"
    # Supaya client tidak perlu login username/password server
    try {
        $netSharePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        Set-ItemProperty -Path $netSharePath -Name "everyoneincludesanonymous" -Value 1 -Force
        Set-ItemProperty -Path $netSharePath -Name "restrictanonymous"         -Value 0 -Force

        # Via PowerShell SMB config
        Set-SmbServerConfiguration `
            -RequireSecuritySignature $false `
            -EnableSecuritySignature  $false `
            -RestrictNullSessAccess   $false `
            -Force 2>$null

        # Via netsh
        netsh advfirewall firewall set rule `
            name="File and Printer Sharing (NB-Session-In)" new enable=Yes 2>$null | Out-Null

        OK "Password Protected Sharing dinonaktifkan"
        INFO "Client tidak perlu username/password untuk connect"
    } catch {
        FAIL "Gagal otomatis — lakukan manual:"
        Write-Host "    Control Panel → Network → Advanced sharing settings"
        Write-Host "    → Turn off password protected sharing"
    }

    HEAD "STEP 6 — Aktifkan Network Discovery di server"
    netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes 2>$null | Out-Null
    OK "Network Discovery aktif"

    HEAD "STEP 7 — Pilih & Share Printer"
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) {
        FAIL "Tidak ada printer terinstall. Install driver dulu."
        WAIT; return
    }

    Write-Host ""
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $tag = if ($printers[$i].Shared) { "[Shared]" } else { "" }
        Write-Host ("  {0,2}. {1} {2}" -f ($i+1), $printers[$i].Name, $tag)
    }
    Write-Host ""
    $raw = Read-Host "  Pilih nomor printer (Enter = skip)"
    if ($raw -match '^\d+$') {
        $idx = [int]$raw - 1
        if ($idx -ge 0 -and $idx -lt $printers.Count) {
            $p = $printers[$idx]
            $sn = Read-Host "  Nama Share (Enter = PRINTER_SEKOLAH)"
            if ([string]::IsNullOrWhiteSpace($sn)) { $sn = "PRINTER_SEKOLAH" }
            $sn = $sn -replace '[^\w\-]','_'

            try {
                Set-Printer -Name $p.Name -Shared $true -ShareName $sn -ErrorAction Stop
                OK "Printer '$($p.Name)' di-share sebagai '$sn'"
            } catch {
                FAIL "Gagal share: $_"
            }
        }
    } else {
        INFO "Skip — share printer bisa dilakukan di menu Share Printer"
    }

    HEAD "HASIL — Informasi untuk diberikan ke teknisi client"
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  INFORMASI SERVER (catat untuk client)  │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Nama Komputer  : " -NoNewline; Write-Host $env:COMPUTERNAME -ForegroundColor Yellow
    Write-Host "  Workgroup      : " -NoNewline

    $wg = (Get-WmiObject Win32_ComputerSystem 2>$null).Workgroup
    Write-Host $wg -ForegroundColor Yellow

    Write-Host ""
    Get-NetIPAddress -AddressFamily IPv4 2>$null |
    Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.' } |
    ForEach-Object {
        $a = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex 2>$null
        $nm = if ($a) { $a.Name } else { "?" }
        Write-Host ("  IP [{0}] : " -f $nm) -NoNewline
        Write-Host $_.IPAddress -ForegroundColor Yellow
    }

    Write-Host ""
    $shared = @(Get-Printer 2>$null | Where-Object { $_.Shared })
    if ($shared.Count -gt 0) {
        foreach ($sp in $shared) {
            Write-Host "  Path Share     : " -NoNewline
            Write-Host "\\$env:COMPUTERNAME\$($sp.ShareName)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    WAIT
}

# ================================================================
#  B. SETUP CLIENT — konfigurasi semua yang diperlukan di PC client
# ================================================================
function Setup-Client {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║      SETUP CLIENT (PC yang mau pakai     ║" -ForegroundColor Magenta
    Write-Host "  ║      printer lewat jaringan)             ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta

    HEAD "STEP 1 — Network Profile → Private"
    $changed = 0
    Get-NetConnectionProfile 2>$null |
    Where-Object { $_.NetworkCategory -eq 'Public' } |
    ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
        OK "[$($_.Name)] Public → Private"
        $changed++
    }
    if ($changed -eq 0) { OK "Semua profile sudah Private" }

    HEAD "STEP 2 — Firewall: File & Printer Sharing (client)"
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes 2>$null | Out-Null
    netsh advfirewall firewall set rule group="Network Discovery"         new enable=Yes 2>$null | Out-Null
    OK "Firewall rules diaktifkan"

    HEAD "STEP 3 — SMB Client (LanmanWorkstation)"
    Set-Service LanmanWorkstation -StartupType Automatic 2>$null
    Start-Service LanmanWorkstation 2>$null
    OK "SMB Client service: Running"

    HEAD "STEP 4 — SMB2 protokol (wajib Win10)"
    try {
        Set-SmbClientConfiguration -EnableMultichannel $true -Force 2>$null
        OK "SMB Client dikonfigurasi"
    } catch { INFO "Skip konfigurasi SMB client (tidak kritis)" }

    HEAD "STEP 5 — Input data server"
    Write-Host ""
    $server = Read-Host "  IP Server (contoh: 192.168.1.10)"
    $share  = Read-Host "  Nama Share (contoh: PRINTER_SEKOLAH)"

    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($share)) {
        FAIL "IP dan nama share wajib diisi."; WAIT; return
    }

    $unc = "\\$server\$share"

    HEAD "STEP 6 — Test koneksi ke server"
    Write-Host ""
    Write-Host "  Ping $server ..." -NoNewline
    $ping = Test-Connection -ComputerName $server -Count 2 -Quiet 2>$null
    if ($ping) {
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Host " GAGAL" -ForegroundColor Red
        FAIL "Server tidak merespons. Cek:"
        Write-Host "    - Kabel/WiFi tersambung ke jaringan yang sama"
        Write-Host "    - IP server benar"
        Write-Host "    - Server menyala"
        $lanjut = Read-Host "`n  Tetap lanjut? (y/N)"
        if ($lanjut -notmatch '^[yY]$') { WAIT; return }
    }

    HEAD "STEP 7 — Test akses path jaringan"
    Write-Host "  Akses $unc ..." -NoNewline
    $reach = Test-Path $unc 2>$null
    if (-not $reach) {
        Write-Host " GAGAL" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Path tidak bisa diakses. Pilihan:" -ForegroundColor Yellow
        Write-Host "    [1] Coba dengan username/password server"
        Write-Host "    [2] Batal"
        Write-Host ""
        $opt = Read-Host "  Pilih"
        if ($opt -eq "1") {
            $user    = Read-Host "  Username server"
            $secPass = Read-Host "  Password" -AsSecureString
            $plainP  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))

            cmdkey /delete:"$server" 2>$null | Out-Null
            cmdkey /add:"$server" /user:"$user" /pass:"$plainP" 2>$null | Out-Null
            net use "\\$server" /user:"$user" "$plainP" /persistent:yes 2>&1 | Out-Null

            $reach = Test-Path $unc 2>$null
            if (-not $reach) {
                FAIL "Masih gagal. Kemungkinan nama share salah atau firewall server."
                WAIT; return
            }
            OK "Autentikasi berhasil"
        } else {
            WAIT; return
        }
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    HEAD "STEP 8 — Install printer"
    Write-Host "  Menambahkan printer $unc ..."
    $added = $false

    # Metode 1
    try { Add-Printer -ConnectionName $unc -ErrorAction Stop; $added = $true } catch { }

    # Metode 2
    if (-not $added) {
        try {
            $net = New-Object -ComObject WScript.Network
            $net.AddWindowsPrinterConnection($unc)
            $added = $true
        } catch { }
    }

    # Metode 3
    if (-not $added) {
        try {
            net use "\\$server" /persistent:no 2>$null | Out-Null
            Add-Printer -ConnectionName $unc -ErrorAction Stop
            $added = $true
        } catch { }
    }

    # Metode 4
    if (-not $added) {
        try {
            $p = Start-Process "rundll32.exe" `
                -ArgumentList "printui.dll,PrintUIEntry /in /n `"$unc`"" `
                -Wait -PassThru
            if ($p.ExitCode -eq 0) { $added = $true }
        } catch { }
    }

    Write-Host ""
    if ($added) {
        OK "Printer berhasil ditambahkan: $unc"
        INFO "Cek: Settings > Printers & scanners"
    } else {
        FAIL "Gagal otomatis. Lakukan manual:"
        Write-Host "    1. File Explorer → address bar ketik: \\$server"
        Write-Host "    2. Double-click ikon printer '$share'"
        Write-Host "    3. Windows akan install driver dari server"
        Write-Host ""
        INFO "Atau: Jika driver tidak ada di server, install driver"
        INFO "Epson L3210 di client dulu, baru ulangi langkah ini."
    }

    WAIT
}

# ================================================================
#  C. SHARE PRINTER (cepat, tanpa full setup)
# ================================================================
function Share-Printer {
    Clear-Host
    HEAD "SHARE PRINTER"

    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) { FAIL "Tidak ada printer."; WAIT; return }

    Write-Host ""
    for ($i = 0; $i -lt $printers.Count; $i++) {
        $tag = if ($printers[$i].Shared) { "[Shared]" } else { "" }
        Write-Host ("  {0,2}. {1} {2}" -f ($i+1), $printers[$i].Name, $tag)
    }
    Write-Host ""
    $raw = Read-Host "  Pilih nomor"
    if ($raw -notmatch '^\d+$') { FAIL "Input tidak valid."; WAIT; return }

    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $printers.Count) { FAIL "Nomor di luar range."; WAIT; return }

    $p  = $printers[$idx]
    $sn = Read-Host "  Nama Share (Enter = PRINTER_SEKOLAH)"
    if ([string]::IsNullOrWhiteSpace($sn)) { $sn = "PRINTER_SEKOLAH" }
    $sn = $sn -replace '[^\w\-]','_'

    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes 2>$null | Out-Null

    try {
        Set-Printer -Name $p.Name -Shared $true -ShareName $sn -ErrorAction Stop
        Write-Host ""
        OK "Berhasil di-share!"
        Write-Host "  Path : " -NoNewline; Write-Host "\\$env:COMPUTERNAME\$sn" -ForegroundColor Yellow

        $ips = @(Get-NetIPAddress -AddressFamily IPv4 2>$null |
                 Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.' } |
                 Select-Object -ExpandProperty IPAddress)
        Write-Host "  IP   : " -NoNewline; Write-Host ($ips -join "  |  ") -ForegroundColor Yellow
    } catch {
        FAIL "Gagal: $_"
    }
    WAIT
}

# ================================================================
#  D. CONNECT PRINTER (cepat, tanpa full setup)
# ================================================================
function Connect-Printer-Quick {
    Clear-Host
    HEAD "CONNECT PRINTER"
    Write-Host ""
    $server = Read-Host "  IP Server"
    $share  = Read-Host "  Nama Share"
    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($share)) {
        FAIL "Tidak boleh kosong."; WAIT; return
    }

    $unc = "\\$server\$share"
    Write-Host ""
    Write-Host "  Menambahkan $unc ..." -NoNewline

    $added = $false
    try { Add-Printer -ConnectionName $unc -ErrorAction Stop; $added = $true } catch { }
    if (-not $added) {
        try {
            $net = New-Object -ComObject WScript.Network
            $net.AddWindowsPrinterConnection($unc); $added = $true
        } catch { }
    }
    if (-not $added) {
        $p = Start-Process "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /in /n `"$unc`"" -Wait -PassThru 2>$null
        if ($p -and $p.ExitCode -eq 0) { $added = $true }
    }

    if ($added) { Write-Host " OK" -ForegroundColor Green; OK "Printer ditambahkan." }
    else        { Write-Host " GAGAL" -ForegroundColor Red; FAIL "Jalankan Setup Client (Menu 2) untuk troubleshooting lengkap." }
    WAIT
}

# ================================================================
#  E. LIST PRINTER
# ================================================================
function List-Printers {
    Clear-Host
    HEAD "DAFTAR PRINTER"
    Write-Host ""
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) { INFO "Tidak ada printer."; WAIT; return }
    $printers | Format-Table `
        @{L="No"      ; E={ [array]::IndexOf($printers,$_)+1 }; W=4  },
        @{L="Nama"    ; E={ $_.Name }                          ; W=38 },
        @{L="Shared"  ; E={ $_.Shared }                        ; W=7  },
        @{L="Default" ; E={ $_.Default }                       ; W=8  },
        @{L="Type"    ; E={ $_.Type }                          ; W=8  },
        @{L="Status"  ; E={ $_.PrinterStatus }                 ; W=10 } `
        -AutoSize
    WAIT
}

# ================================================================
#  F. SET DEFAULT PRINTER
# ================================================================
function Set-Default-Printer {
    Clear-Host
    HEAD "SET DEFAULT PRINTER"
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) { FAIL "Tidak ada printer."; WAIT; return }
    Write-Host ""
    for ($i=0; $i -lt $printers.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i+1), $printers[$i].Name)
    }
    Write-Host ""
    $raw = Read-Host "  Pilih nomor"
    if ($raw -notmatch '^\d+$') { FAIL "Input tidak valid."; WAIT; return }
    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $printers.Count) { FAIL "Di luar range."; WAIT; return }

    # Matikan "Let Windows manage default printer"
    Set-ItemProperty `
        "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows" `
        -Name "LegacyDefaultPrinterMode" -Value 1 -Type DWord -Force 2>$null

    $ok = $false
    try {
        $net = New-Object -ComObject WScript.Network
        $net.SetDefaultPrinter($printers[$idx].Name)
        $ok = $true
    } catch { }
    if (-not $ok) {
        Set-ItemProperty `
            "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows" `
            -Name "Device" -Value "$($printers[$idx].Name),winspool,Ne00:" -Force 2>$null
        $ok = $true
    }

    if ($ok) { OK "Default: $($printers[$idx].Name)" }
    else     { FAIL "Gagal." }
    WAIT
}

# ================================================================
#  G. HAPUS PRINTER
# ================================================================
function Remove-Printer-Menu {
    Clear-Host
    HEAD "HAPUS PRINTER"
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) { INFO "Tidak ada printer."; WAIT; return }
    Write-Host ""
    for ($i=0; $i -lt $printers.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i+1), $printers[$i].Name)
    }
    Write-Host ""
    $raw = Read-Host "  Pilih nomor"
    if ($raw -notmatch '^\d+$') { FAIL "Input tidak valid."; WAIT; return }
    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $printers.Count) { FAIL "Di luar range."; WAIT; return }

    $nama = $printers[$idx].Name
    $confirm = Read-Host "  Hapus '$nama'? (y/N)"
    if ($confirm -notmatch '^[yY]$') { INFO "Dibatalkan."; WAIT; return }

    $ok = $false
    try { Remove-Printer -Name $nama -ErrorAction Stop; $ok = $true } catch { }
    if (-not $ok) {
        Start-Process "rundll32.exe" `
            -ArgumentList "printui.dll,PrintUIEntry /dl /n `"$nama`"" -Wait 2>$null
        $ok = $true
    }
    if ($ok) { OK "Printer '$nama' dihapus." } else { FAIL "Gagal." }
    WAIT
}

# ================================================================
#  H. DIAGNOSTIK LENGKAP (untuk teknisi)
# ================================================================
function Run-Diagnostics {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          LAPORAN DIAGNOSTIK TEKNISI              ║" -ForegroundColor Cyan
    Write-Host "  ║  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')                          ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # ── IDENTITAS KOMPUTER ──────────────────────────────────────
    HEAD "IDENTITAS KOMPUTER"
    $cs = Get-WmiObject Win32_ComputerSystem 2>$null
    $os = Get-WmiObject Win32_OperatingSystem 2>$null
    Write-Host ""
    Write-Host "  Nama Komputer   : " -NoNewline; Write-Host $env:COMPUTERNAME         -ForegroundColor Yellow
    Write-Host "  Workgroup/Domain: " -NoNewline; Write-Host $cs.Workgroup              -ForegroundColor Yellow
    Write-Host "  Login sebagai   : " -NoNewline; Write-Host $env:USERNAME              -ForegroundColor Yellow
    Write-Host "  OS              : " -NoNewline; Write-Host $os.Caption                -ForegroundColor Yellow
    Write-Host "  OS Build        : " -NoNewline; Write-Host $os.BuildNumber            -ForegroundColor Yellow
    Write-Host "  OS Arch         : " -NoNewline; Write-Host $os.OSArchitecture         -ForegroundColor Yellow
    Write-Host "  RAM             : " -NoNewline
    Write-Host ("{0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB))                        -ForegroundColor Yellow

    # ── NETWORK ADAPTERS DETAIL ─────────────────────────────────
    HEAD "NETWORK ADAPTERS (semua)"
    Write-Host ""
    $adapters = Get-NetAdapter 2>$null | Where-Object { $_.Status -eq 'Up' }
    foreach ($a in $adapters) {
        $ipInfo = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 2>$null |
                  Where-Object { $_.IPAddress -notmatch '^127\.' }
        $gw     = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix "0.0.0.0/0" 2>$null |
                   Select-Object -First 1).NextHop
        $dns    = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 2>$null).ServerAddresses

        Write-Host "  ┌── Adapter    : " -NoNewline; Write-Host $a.Name              -ForegroundColor Yellow
        Write-Host "  │   Deskripsi  : $($a.InterfaceDescription)"
        Write-Host "  │   MAC Address: " -NoNewline; Write-Host $a.MacAddress        -ForegroundColor Yellow
        Write-Host "  │   Link Speed : $($a.LinkSpeed)"

        if ($ipInfo) {
            Write-Host "  │   IP Address : " -NoNewline; Write-Host $ipInfo.IPAddress      -ForegroundColor Green
            Write-Host "  │   Prefix Len : /$($ipInfo.PrefixLength)"

            # Hitung subnet mask dari prefix length
            $pl = $ipInfo.PrefixLength
            if ($pl) {
                $mask = [Convert]::ToUInt32(('1' * $pl + '0' * (32-$pl)), 2)
                $bytes = [BitConverter]::GetBytes($mask)
                [Array]::Reverse($bytes)
                $subnetMask = $bytes -join '.'
                Write-Host "  │   Subnet Mask: $subnetMask"
            }
        } else {
            Write-Host "  │   IP Address : (tidak ada)"
        }

        Write-Host "  │   Gateway    : " -NoNewline
        if ($gw) { Write-Host $gw -ForegroundColor Cyan } else { Write-Host "-" }
        Write-Host "  │   DNS Server : " -NoNewline
        if ($dns) { Write-Host ($dns -join ", ") -ForegroundColor Cyan } else { Write-Host "-" }

        $profile = (Get-NetConnectionProfile -InterfaceIndex $a.ifIndex 2>$null).NetworkCategory
        $col = if ($profile -eq 'Private') { 'Green' } else { 'Red' }
        Write-Host "  └── Net Profile : " -NoNewline; Write-Host $profile -ForegroundColor $col
        Write-Host ""
    }

    $downAdapters = Get-NetAdapter 2>$null | Where-Object { $_.Status -ne 'Up' }
    foreach ($a in $downAdapters) {
        Write-Host "  [DOWN] $($a.Name) — $($a.InterfaceDescription)" -ForegroundColor DarkGray
    }

    # ── SERVICES STATUS ─────────────────────────────────────────
    HEAD "STATUS SERVICES PENTING"
    Write-Host ""
    $services = @(
        @{ Name="Spooler";           Label="Print Spooler         " },
        @{ Name="LanmanServer";      Label="SMB Server            " },
        @{ Name="LanmanWorkstation"; Label="SMB Client (Workstatn)" },
        @{ Name="Browser";           Label="Computer Browser      " },
        @{ Name="lmhosts";           Label="TCP/IP NetBIOS Helper " },
        @{ Name="Netlogon";          Label="Net Logon             " }
    )
    foreach ($svc in $services) {
        $s   = Get-Service $svc.Name 2>$null
        $st  = if ($s) { $s.Status } else { "Tidak ada" }
        $col = if ($st -eq 'Running') { 'Green' } elseif ($st -eq 'Stopped') { 'Red' } else { 'DarkGray' }
        Write-Host ("  {0}: " -f $svc.Label) -NoNewline
        Write-Host $st -ForegroundColor $col
    }

    # ── FIREWALL STATUS ─────────────────────────────────────────
    HEAD "FIREWALL"
    Write-Host ""
    $fwProfiles = Get-NetFirewallProfile 2>$null
    foreach ($fp in $fwProfiles) {
        $col = if ($fp.Enabled) { 'Yellow' } else { 'DarkGray' }
        Write-Host ("  Profile [{0,-9}]: Firewall " -f $fp.Name) -NoNewline
        Write-Host (if ($fp.Enabled) { "ON" } else { "OFF" }) -ForegroundColor $col
    }
    Write-Host ""
    $fwGroups = @("File and Printer Sharing","Network Discovery","Printer Sharing")
    foreach ($g in $fwGroups) {
        $rules = @(Get-NetFirewallRule 2>$null |
                   Where-Object { $_.DisplayGroup -like "*$g*" -and $_.Enabled -eq $true })
        $st  = if ($rules.Count -gt 0) { "Aktif ($($rules.Count) rules)" } else { "NONAKTIF" }
        $col = if ($rules.Count -gt 0) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-30}: " -f $g) -NoNewline
        Write-Host $st -ForegroundColor $col
    }

    # ── SMB KONFIGURASI ─────────────────────────────────────────
    HEAD "SMB KONFIGURASI"
    Write-Host ""
    $smbSrv = Get-SmbServerConfiguration 2>$null
    $smbCli = Get-SmbClientConfiguration 2>$null
    if ($smbSrv) {
        Write-Host "  SMB1 Server Enabled    : " -NoNewline
        $col = if ($smbSrv.EnableSMB1Protocol) { 'Yellow' } else { 'Green' }
        Write-Host $smbSrv.EnableSMB1Protocol -ForegroundColor $col
        Write-Host "  SMB2 Server Enabled    : " -NoNewline
        Write-Host $smbSrv.EnableSMB2Protocol -ForegroundColor Green
        Write-Host "  Require Security Sign  : $($smbSrv.RequireSecuritySignature)"
        Write-Host "  AutoDisconnect (menit) : $($smbSrv.AutoDisconnectTimeout)"
    }
    if ($smbCli) {
        Write-Host "  SMB1 Client Enabled    : " -NoNewline
        $col = if ($smbCli.EnableSMB1Protocol) { 'Yellow' } else { 'Green' }
        Write-Host $smbCli.EnableSMB1Protocol -ForegroundColor $col
    }

    # ── PRINTER DETAIL ──────────────────────────────────────────
    HEAD "PRINTER TERINSTALL"
    Write-Host ""
    $printers = @(Get-Printer 2>$null)
    if ($printers.Count -eq 0) {
        Write-Host "  (tidak ada printer)" -ForegroundColor DarkGray
    } else {
        foreach ($p in $printers) {
            $col = if ($p.PrinterStatus -eq 'Normal') { 'Green' } else { 'Red' }
            Write-Host "  ┌── Nama      : " -NoNewline; Write-Host $p.Name           -ForegroundColor Yellow
            Write-Host "  │   Driver    : $($p.DriverName)"
            Write-Host "  │   Port      : $($p.PortName)"
            Write-Host "  │   Shared    : " -NoNewline
            if ($p.Shared) {
                Write-Host "Ya  →  \\$env:COMPUTERNAME\$($p.ShareName)" -ForegroundColor Green
            } else {
                Write-Host "Tidak" -ForegroundColor DarkGray
            }
            Write-Host "  │   Default   : $($p.Default)"
            Write-Host "  └── Status    : " -NoNewline; Write-Host $p.PrinterStatus  -ForegroundColor $col
            Write-Host ""
        }
    }

    # ── PING TEST ───────────────────────────────────────────────
    HEAD "PING TEST GATEWAY"
    Write-Host ""
    $gws = Get-NetRoute -DestinationPrefix "0.0.0.0/0" 2>$null |
           Where-Object { $_.NextHop -ne '0.0.0.0' } |
           Select-Object -ExpandProperty NextHop -Unique
    foreach ($gw in $gws) {
        Write-Host "  Ping $gw ... " -NoNewline
        $ok = Test-Connection -ComputerName $gw -Count 1 -Quiet 2>$null
        if ($ok) { Write-Host "OK" -ForegroundColor Green }
        else     { Write-Host "GAGAL" -ForegroundColor Red }
    }

    # ── SHARED FOLDERS ──────────────────────────────────────────
    HEAD "SHARED FOLDERS (net share)"
    Write-Host ""
    try {
        $shares = Get-SmbShare 2>$null |
                  Where-Object { $_.Name -notmatch '^\w+\$$' }
        foreach ($sh in $shares) {
            Write-Host ("  {0,-20} → {1}" -f $sh.Name, $sh.Path)
        }
    } catch {
        net share 2>$null
    }

    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host "  Selesai: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor DarkGray
    WAIT
}

# ================================================================
#  I. FIX PRINTNIGHTMARE (CVE-2021-1675 / CVE-2021-34527)
# ================================================================
function Fix-PrintNightmare {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║         FIX PRINTNIGHTMARE                       ║" -ForegroundColor Red
    Write-Host "  ║  CVE-2021-1675 / CVE-2021-34527                  ║" -ForegroundColor Red
    Write-Host "  ║  Patch Microsoft yang memblokir printer sharing   ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Jalankan di: " -NoNewline
    Write-Host "SERVER dan CLIENT" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Pilih mode:" -ForegroundColor Cyan
    Write-Host "    1. CEK STATUS — lihat kondisi registry sekarang"
    Write-Host "    2. FIX SERVER — jalankan di PC server (host printer)"
    Write-Host "    3. FIX CLIENT — jalankan di PC client"
    Write-Host "    4. FIX KEDUANYA — jalankan semua fix sekaligus"
    Write-Host "    0. Kembali"
    Write-Host ""
    $mode = Read-Host "  Pilih"

    switch ($mode) {
        "1" { PNM-CheckStatus  }
        "2" { PNM-FixServer    }
        "3" { PNM-FixClient    }
        "4" { PNM-FixServer; PNM-FixClient }
        "0" { return }
        default { FAIL "Pilihan tidak valid." }
    }
    WAIT
}

function PNM-CheckStatus {
    HEAD "STATUS REGISTRY PRINTNIGHTMARE"
    Write-Host ""

    $checks = @(
        @{
            Path  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
            Name  = "RestrictDriverInstallationToAdministrators"
            Ideal = 0
            Label = "RestrictDriverInstall (0=bebas install driver)"
        },
        @{
            Path  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
            Name  = "NoWarningNoElevationOnInstall"
            Ideal = 1
            Label = "NoWarningNoElevation (1=tidak minta UAC)"
        },
        @{
            Path  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
            Name  = "UpdatePromptSettings"
            Ideal = 2
            Label = "UpdatePromptSettings (2=tidak blokir update driver)"
        },
        @{
            Path  = "HKLM:\SYSTEM\CurrentControlSet\Control\Print"
            Name  = "RpcAuthnLevelPrivacyEnabled"
            Ideal = 0
            Label = "RpcAuthnLevelPrivacy (0=izinkan RPC printer lama)"
        },
        @{
            Path  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Providers\LanMan Print Services\Servers"
            Name  = "AddPrinterDrivers"
            Ideal = 1
            Label = "AddPrinterDrivers (1=izinkan tambah driver dari server)"
        }
    )

    foreach ($c in $checks) {
        $val = (Get-ItemProperty -Path $c.Path -Name $c.Name 2>$null).($c.Name)
        Write-Host ("  {0}" -f $c.Label)
        Write-Host "    Path  : $($c.Path)\$($c.Name)"
        Write-Host "    Nilai : " -NoNewline
        if ($null -eq $val) {
            Write-Host "(tidak ada / default Windows)" -ForegroundColor DarkYellow
        } elseif ($val -eq $c.Ideal) {
            Write-Host "$val  ✓ Sudah benar" -ForegroundColor Green
        } else {
            Write-Host "$val  ✗ Perlu diubah ke $($c.Ideal)" -ForegroundColor Red
        }
        Write-Host ""
    }

    # Cek Windows Update terkait PrintNightmare
    HEAD "WINDOWS UPDATE TERKAIT"
    Write-Host ""
    $pnmKBs = @("KB5005033","KB5005031","KB5005010","KB5004945","KB5004237",
                 "KB5004946","KB5004244","KB5004243")
    $installedKBs = Get-HotFix 2>$null | Select-Object -ExpandProperty HotFixID

    foreach ($kb in $pnmKBs) {
        $installed = $installedKBs -contains $kb
        Write-Host "  $kb : " -NoNewline
        if ($installed) {
            Write-Host "Terinstall (patch PrintNightmare aktif)" -ForegroundColor Yellow
        } else {
            Write-Host "Tidak ada" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    INFO "Patch PrintNightmare terinstall = sharing printer diperketat."
    INFO "Fix di bawah akan longgarkan policy-nya tanpa uninstall patch."
}

function PNM-FixServer {
    HEAD "FIX SERVER — PrintNightmare"
    Write-Host ""

    # ── 1. Point and Print Policy ──────────────────────────────
    INFO "[1/6] Point and Print policy..."
    $pnpPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
    if (-not (Test-Path $pnpPath)) {
        New-Item -Path $pnpPath -Force 2>$null | Out-Null
    }
    # Izinkan install driver tanpa UAC untuk printer yang sudah dikenal
    Set-ItemProperty -Path $pnpPath -Name "RestrictDriverInstallationToAdministrators" -Value 0  -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "NoWarningNoElevationOnInstall"               -Value 1  -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "UpdatePromptSettings"                        -Value 2  -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "InForest"                                    -Value 0  -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "Restricted"                                  -Value 0  -Type DWord -Force 2>$null
    OK "Point and Print policy dilonggarkan"

    # ── 2. RPC Privacy — blokir koneksi printer RPC lama ───────
    INFO "[2/6] RPC Authentication Level Privacy..."
    $printPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print"
    Set-ItemProperty -Path $printPath -Name "RpcAuthnLevelPrivacyEnabled" -Value 0 -Type DWord -Force 2>$null
    OK "RpcAuthnLevelPrivacyEnabled = 0 (izinkan RPC printer lama)"

    # ── 3. Izinkan driver dari non-admin (LanMan Print Server) ──
    INFO "[3/6] LanMan Print Services driver policy..."
    $lanPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Providers\LanMan Print Services\Servers"
    if (-not (Test-Path $lanPath)) { New-Item -Path $lanPath -Force 2>$null | Out-Null }
    Set-ItemProperty -Path $lanPath -Name "AddPrinterDrivers" -Value 1 -Type DWord -Force 2>$null
    OK "AddPrinterDrivers = 1"

    # ── 4. Spooler: matikan RestrictDriverInstallation via GPO ──
    INFO "[4/6] Group Policy — paksa disable restriction..."
    $gpPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Providers\LanMan Print Services\Servers"
    if (-not (Test-Path $gpPath)) { New-Item -Path $gpPath -Force 2>$null | Out-Null }
    Set-ItemProperty -Path $gpPath -Name "AddPrinterDrivers" -Value 1 -Type DWord -Force 2>$null
    OK "GPO print server dikonfigurasi"

    # ── 5. Restart Spooler ──────────────────────────────────────
    INFO "[5/6] Restart Print Spooler..."
    Stop-Service Spooler -Force 2>$null
    Start-Sleep -Seconds 2
    Start-Service Spooler 2>$null
    $st = (Get-Service Spooler 2>$null).Status
    if ($st -eq 'Running') { OK "Print Spooler running kembali" }
    else { FAIL "Spooler gagal start — cek Event Viewer" }

    # ── 6. Package Point and Print ──────────────────────────────
    INFO "[6/6] Package Point and Print restriction..."
    $pkgPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers"
    if (-not (Test-Path $pkgPath)) { New-Item -Path $pkgPath -Force 2>$null | Out-Null }
    Set-ItemProperty -Path $pkgPath -Name "PackagePointAndPrintOnly"           -Value 0 -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pkgPath -Name "PackagePointAndPrintServerList"     -Value 0 -Type DWord -Force 2>$null
    OK "Package Point and Print restriction dinonaktifkan"

    Write-Host ""
    OK "FIX SERVER selesai."
    INFO "Jika sebelumnya ada Group Policy dari domain, fix ini mungkin"
    INFO "tertimpa setelah gpupdate. Hubungi admin jaringan/domain jika itu terjadi."
}

function PNM-FixClient {
    HEAD "FIX CLIENT — PrintNightmare"
    Write-Host ""

    # ── 1. Point and Print sama seperti server ──────────────────
    INFO "[1/4] Point and Print policy di client..."
    $pnpPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint"
    if (-not (Test-Path $pnpPath)) { New-Item -Path $pnpPath -Force 2>$null | Out-Null }
    Set-ItemProperty -Path $pnpPath -Name "RestrictDriverInstallationToAdministrators" -Value 0 -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "NoWarningNoElevationOnInstall"               -Value 1 -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pnpPath -Name "UpdatePromptSettings"                        -Value 2 -Type DWord -Force 2>$null
    OK "Point and Print policy dilonggarkan"

    # ── 2. RPC di client ────────────────────────────────────────
    INFO "[2/4] RPC Authentication Level di client..."
    $printPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print"
    Set-ItemProperty -Path $printPath -Name "RpcAuthnLevelPrivacyEnabled" -Value 0 -Type DWord -Force 2>$null
    OK "RpcAuthnLevelPrivacyEnabled = 0"

    # ── 3. Package Point and Print ──────────────────────────────
    INFO "[3/4] Package Point and Print restriction..."
    $pkgPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers"
    if (-not (Test-Path $pkgPath)) { New-Item -Path $pkgPath -Force 2>$null | Out-Null }
    Set-ItemProperty -Path $pkgPath -Name "PackagePointAndPrintOnly"       -Value 0 -Type DWord -Force 2>$null
    Set-ItemProperty -Path $pkgPath -Name "PackagePointAndPrintServerList" -Value 0 -Type DWord -Force 2>$null
    OK "Package Point and Print dinonaktifkan"

    # ── 4. Restart Spooler client ────────────────────────────────
    INFO "[4/4] Restart Print Spooler client..."
    Stop-Service Spooler -Force 2>$null
    Start-Sleep -Seconds 2
    Start-Service Spooler 2>$null
    $st = (Get-Service Spooler 2>$null).Status
    if ($st -eq 'Running') { OK "Print Spooler running" }
    else { FAIL "Spooler gagal — cek Event Viewer" }

    Write-Host ""
    OK "FIX CLIENT selesai."
    INFO "Sekarang coba connect ulang ke printer server."
    INFO "Gunakan Menu 4 (Connect Printer) atau double-click printer di File Explorer."
}

# ================================================================
#  MENU UTAMA
# ================================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║        WINDOWS SHARING PRINTER             ║" -ForegroundColor Cyan
    Write-Host "  ║        Windows 10  |  Full Support        ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ── SETUP ─────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  1. Setup SERVER  (jalankan di PC yang punya printer)"
    Write-Host "  2. Setup CLIENT  (jalankan di PC yang mau pakai printer)"
    Write-Host ""
    Write-Host "  ── MANAJEMEN PRINTER ─────────────────────────" -ForegroundColor Yellow
    Write-Host "  3. Share Printer    (cepat, server sudah siap)"
    Write-Host "  4. Connect Printer  (cepat, client sudah siap)"
    Write-Host "  5. List Printer"
    Write-Host "  6. Set Default Printer"
    Write-Host "  7. Hapus Printer"
    Write-Host ""
    Write-Host "  ── ALAT TEKNISI ──────────────────────────────" -ForegroundColor Yellow
    Write-Host "  8. Diagnostik Lengkap (IP, SMB, firewall, dll)"
    Write-Host "  9. Fix PrintNightmare (CVE-2021-1675/34527)  " -ForegroundColor Red
    Write-Host ""
    Write-Host "  0. Keluar"
    Write-Host ""
}

# ================================================================
#  LOOP UTAMA
# ================================================================
$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host "  Pilih Menu"
    switch ($choice) {
        "1" { Setup-Server         }
        "2" { Setup-Client         }
        "3" { Share-Printer        }
        "4" { Connect-Printer-Quick }
        "5" { List-Printers        }
        "6" { Set-Default-Printer  }
        "7" { Remove-Printer-Menu  }
        "8" { Run-Diagnostics      }
        "9" { Fix-PrintNightmare   }
        "0" { $running = $false    }
        default {
            FAIL "Pilihan tidak valid."
            Start-Sleep -Milliseconds 800
        }
    }
}

Write-Host ""
Write-Host "  Sampai jumpa!" -ForegroundColor Cyan
Write-Host ""

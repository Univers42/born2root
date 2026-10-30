# vm_share_connect.ps1 -- the colleague's side of make share_invite, for
# Windows: powershell -ExecutionPolicy Bypass -File connect-@ALIAS@.ps1
# The twin of vm_share_connect.sh (its header has the why); vm_share.sh
# fills the @...@ fields in per guest. OpenSSH ships with Windows 10 1809+.
# The config is written as ASCII: Windows PowerShell's UTF-8 adds a BOM,
# which ssh reads as a bad first keyword.
# An invite without a key leaves PubKey empty: the key made here is tried on
# every run and connects once the owner has run make share_key.
# The block forwards the agent (the .sh header has the why). Windows ships
# its ssh-agent service disabled, and enabling it takes an administrator: the
# kit asks for that rather than connecting without a key for git push.
# Caveat: the address is the VM's tailnet IP when the kit was made; after a
# rebuild the owner sends a new kit.
$Alias = '@ALIAS@'
$HostIp = '@HOST@'
$Port = '@PORT@'
$Login = '@LOGIN@'
$PubKey = '@PUBKEY@'

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host 'No ssh here: Settings > System > Optional features > add "OpenSSH Client".'
    exit 1
}
$sshDir = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

$out = (& ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new `
        -o PreferredAuthentications=none -p $Port "$Login@$HostIp" true 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -and $out -notmatch 'Permission denied') {
    Write-Host "$Alias ($HostIp`:$Port) does not answer: $($out.Trim())"
    Write-Host 'Is Tailscale running and logged in, with the invite mail accepted?'
    Write-Host "The machine $Alias has to be listed by: tailscale status"
    exit 1
}

$want = ($PubKey -split ' ')[1]
$key = $null
foreach ($pub in Get-ChildItem -Path $sshDir -Filter '*.pub' -ErrorAction SilentlyContinue) {
    $private = $pub.FullName -replace '\.pub$', ''
    if ($want -and ((Get-Content $pub.FullName -TotalCount 1) -split ' ')[1] -eq $want -and (Test-Path $private)) {
        $key = $private
        break
    }
}
$newKey = $false
if (-not $key) {
    $key = Join-Path $sshDir "id_ed25519_$Alias"
    if (-not (Test-Path $key)) {
        Write-Host "No key here that $Alias knows: making $key (a passphrase is up to you)."
        & ssh-keygen -q -t ed25519 -f $key -C "$Login@$Alias"
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
    $newKey = $true
}

$cfg = Join-Path $sshDir 'config'
$begin = "# >>> b2b $Alias"
$end = "# <<< b2b $Alias"
$block = @($begin, "Host $Alias", "    HostName $HostIp", "    Port $Port", "    User $Login",
    "    IdentityFile `"$key`"", '    IdentitiesOnly yes', '    ForwardAgent yes', '    AddKeysToAgent yes', $end)
$rest = @()
if (Test-Path $cfg) {
    $skip = $false
    foreach ($line in Get-Content $cfg) {
        if ($line -eq $begin) { $skip = $true }
        if (-not $skip) { $rest += $line }
        if ($line -eq $end) { $skip = $false }
    }
}
Set-Content -Path $cfg -Value ($block + $rest) -Encoding ascii
Write-Host "~/.ssh/config: Host $Alias -> $Login@$HostIp`:$Port"

if ($newKey) {
    & ssh -o BatchMode=yes -o PreferredAuthentications=publickey $Alias true 2>$null
    if ($LASTEXITCODE -eq 0) { $newKey = $false }
}
if ($newKey) {
    Write-Host "Send this line to the owner of $Alias, then run this script again:"
    Get-Content "$key.pub"
    exit 0
}
$agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
if ($agent -and $agent.Status -eq 'Running') {
    & ssh-add $key 2>$null | Out-Null
} else {
    Write-Host "git push from $Alias needs Windows' ssh-agent. Once, in an administrator PowerShell:"
    Write-Host '    Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent'
    Write-Host 'then run this script again.'
}
Write-Host "From now on: ssh $Alias"
& ssh $Alias

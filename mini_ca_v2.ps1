<#
.SYNOPSIS
    Administrerer et lokalt Certificate Authority (CA) system og utsteder klient-sertifikater.

.DESCRIPTION
    Dette skriptet er ment for laboratorie-/testmiljøer. Det setter opp en privat rot-CA,
    sikrer at tilliten etableres på maskinen, og utsteder deretter nye sertifikater
    til lokalmaskinen og den aktuelle brukeren.

.NOTES
    Kjør alltid som Administrator! (Må ha Local Machine rettigheter)
    Dette er en simulering og erstatter IKKE ADCS eller kommersielle PKI-løsninger.
#>

# --- Global Variabler og Konstanter ---
$TempDirectory = "C:\certtemp"
$RootCAFileName = "branngubbeRootCA.cer"
$ClientDNSName = "mylabserver.branngubbelab.com"
$RootCADNSName = "Branngubbe Lab CA"

# ----------------------------------------------------
# [HELPER FUNKSJONER] - Hjelpefunksjoner for robusthet
# ----------------------------------------------------

Function Test-AdminRights {
    <# Sjekker om skriptet kjører med administratorrettigheter. #>
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
        Write-Error "Feil: Dette skriptet MÅ kjøres som Administrator for å kunne modifisere Local Machine KeyStore."
        exit 1
    }
    Write-Host "[INFO] Administratorrettigheter bekreftet." -ForegroundColor Green
}

Function Cleanup-TempFiles {
    <# Fjerner den midlertidige katalogkatalogen. #>
    if (Test-Path $TempDirectory) {
        try {
            Remove-Item -Path $TempDirectory -Recurse -Force -ErrorAction Stop
            Write-Host "[CLEANUP] Rydde opp i midlertidige filer ($TempDirectory)." -ForegroundColor Yellow
        } catch {
            Write-Warning "Kunne ikke rydde opp i temp-mappen: $_.Exception.Message"
        }
    }
}


# ----------------------------------------------------
# [FASE 1] - ROOT CA SETUP (Kjøres kun ved første gangs installasjon)
# ----------------------------------------------------

Function Setup-RootCA {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TempPath,
        [Parameter(Mandatory=$false)]
        [string]$DNSName = "SystemCenterDudes Lab CA"
    )

    # sjekk om CA allerede eksisterer for å unngå duplikater
    $existingCA = Get-ChildItem "cert:\LocalMachine\root" | Where-Object { $_.Subject -like "*$DNSName*" }

    if ($existingCA) {
        Write-Host "[INFO] En eksisterende CA med DNS '$DNSName' ble funnet. Bruker denne i stedet for å opprette en ny." -ForegroundColor Yellow
        return $existingCA
    }

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "         FASE 1: OPPSETT AV ROOT CERTIFICATE AUTHORITY (CA)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

   
    # Oppsett av katalog og sikkerhetskontroll
    try {
        if (-not (Test-Path $TempPath)) {
            mkdir $TempPath | Out-Null
            Write-Host "[INFO] Oprettet midlertidig katalog: $TempPath"
        }
    } catch {
        Write-Error "Kritisk feil ved opprettelse av katalogen. Avbryter."
        return $null
    }

    # 1. Generer Rot CA-sertifikat
    try {
         Write-Host "[INFO] Genererer Root CA sertifikat for DNS: $DNSName" -ForegroundColor Green
        $rootcert = New-SelfSignedCertificate `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -DnsName $DNSName `
             -Subject "CN=$DNSName, OU=LabCA, O=Branngubbe Labs" `
            -KeyUsage CertSign `
            -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(90) `
            -KeyLength 2048 
        Write-Host "[SUCCESS] Rot CA generert. Thumbprint: $($rootcert.Thumbprint)" -ForegroundColor Green
    } catch {
        Write-Error "Feil ved generering av Root CA: $_"
        return $null
    }

    # 2. Eksporter og distribuer rot CA
    try {
        Export-Certificate -Cert $rootcert -FilePath "$TempPath\$RootCAFileName" -ErrorAction Stop
        Write-Host "[SUCCESS] Rot CA eksportert til: $TempPath\$RootCAFileName" -ForegroundColor Green

        # 3. Importer sertifikatet i Local Machine Root Store (Kritisk for laben!)
        Import-Certificate -FilePath "$TempPath\$RootCAFileName" -CertStoreLocation "Cert:\LocalMachine\Root" -ErrorAction Stop
        Write-Host "[SUCCESS] Rot CA importert som en betrodd rot på alle maskiner." -ForegroundColor Green

    } catch {
        Write-Error "Kritisk feil under tillitsdistribusjon: $_. Sjekk at du kjører med Administrator rettigheter."
        return $null
    }
    
    # 4. Returner den aktive Root CA objektet for neste fase
    $activeRootCA = Get-ChildItem "cert:\CurrentUser\My" | Where-Object {$_.Thumbprint -eq $rootcert.Thumbprint}
    if ($activeRootCA) {
        return $activeRootCA
    } else {
        Write-Error "Kunne ikke finne den aktive Root CA for videre bruk."
        return $null
    }
}


# ----------------------------------------------------
# [FASE 2] - KLIENTSERTIFIKAT UTSTEDELSE (Brukes etter at CA er satt opp)
# ----------------------------------------------------

Function Issue-ClientCertificate {
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$IssuingRootCA, # Må være objektet fra Root CA
        [string]$DNSName = $ClientDNSName
    )

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "         FASE 2: UTSTEDELSE AV KLIENTSERTIFIKATER" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan


    # Tvinger brukeren til å bruke den aktive Root CA som signaturkilde
    $SignerCertificate = $IssuingRootCA

    if (-not $SignerCertificate) {
        Write-Error "Kan ikke utstede sertifikat: Ingen gyldig signatursertifikat funnet."
        return
    }

    try {
        # 1. Opprett sertifikat for den lokale maskinen (Local Machine)
        $MachineCert = New-SelfSignedCertificate `
            -certstorelocation "Cert:\LocalMachine\My" `
            -dnsname $DNSName `
            -Signer $SignerCertificate `


        Write-Host "[SUCCESS] Maskinsertifikat for $DNSName utstedt og lagret lokalt." -ForegroundColor Green

        # 2. Opprett sertifikat for den aktuelle brukeren (Current User)
        $UserCert = New-SelfSignedCertificate `
            -certstorelocation "Cert:\CurrentUser\My" `
            -dnsname $DNSName `
            -Signer $SignerCertificate

        Write-Host "[SUCCESS] Brukersertifikat for $DNSName utstedt og lagret lokalt." -ForegroundColor Green
       
    } catch {
        Write-Error "`n[FEIL KRITISK]: Kunne ikke generere sertifikater. Sjekk at du kjører som Administrator.`nFeilmelding: $_"
    }


}


# **************************************************
#                    HOVEDLOGIKK / KJØRINGSBLOKK
# **************************************************

# Sikrer at vi rydder opp uansett hva som skjer.
#Cleanup-TempFiles 

try {
    # 1. Sjekk rettigheter Først!
    Test-AdminRights

    # 2. Kjører Fase 1: Oppsett av Root CA (Dette må kjøres først!)
    $ActiveRootCA = Setup-RootCA -TempPath $TempDirectory -DNSName $RootCADNSName

    if ($ActiveRootCA) {
        Write-Host "`n==========================================================" -ForegroundColor Magenta
        Write-Host "               SETUP SUKSESS! NÅ KUN UTSTEDELSE." -ForegroundColor Magenta
        Write-Host "==========================================================" -ForegroundColor Magenta

        # 3. Kjører Fase 2: Utsteder klient-sertifikater ved hjelp av den aktive CAen
        Issue-ClientCertificate -IssuingRootCA $ActiveRootCA[1] -DNSName $ClientDNSName
    } else {
        Write-Error "`nSKRIPTET MISLYKKES. Kan ikke fortsette uten et gyldig Root CA."
    }

} finally {
    # Dette sikrer at temp-mappen slettes selv om scriptet feiler!
    #Cleanup-TempFiles 
}

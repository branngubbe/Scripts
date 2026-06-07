<#
tekst-til-tale.ps1
En enkel norsk PowerShell tekst-til-tale (TTS) skript som bruker System.Speech.
Bruk: powershell -ExecutionPolicy Bypass -File .\tekst-til-tale.ps1 -Text "Hei verden" [-OutputFile hello.wav] [-Voice "Microsoft Karen Desktop"] [-Rate -2]

#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Text,

    [string]$OutputFile,

    [string]$Voice,

    [int]$Rate = 0
)

try {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

    if ($Voice) {
        $available = $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
        if ($available -contains $Voice) { $synth.SelectVoice($Voice) } else { Write-Host "Stemme ikke funnet, bruker standardstemme." }
    }

    $synth.Rate = $Rate

    if ($OutputFile) {
        $synth.SetOutputToWaveFile($OutputFile)
        $synth.Speak($Text)
        $synth.SetOutputToDefaultAudioDevice()
        Write-Host "Laget fil:" $OutputFile
    } else {
        $synth.Speak($Text)
    }

    $synth.Dispose()
} catch {
    Write-Error "Feil under TTS: $_"
    exit 1
}

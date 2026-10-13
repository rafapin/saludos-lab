param(
    [string]$ResourceGroup = 'rg-saludos-e1-20261013',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if ($ResourceGroup -notmatch '^rg-saludos-e1-[0-9]{8}$') {
    throw 'El grupo debe seguir el patrón exclusivo del laboratorio rg-saludos-e1-AAAAMMDD.'
}
$exists = (& az group exists -n $ResourceGroup --only-show-errors).Trim()
if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar el grupo en Azure.' }
if ($exists -ne 'true') {
    Write-Host "El grupo $ResourceGroup ya no existe."
    return
}
Write-Host "Grupo a eliminar: $ResourceGroup"
& az resource list -g $ResourceGroup --query '[].{nombre:name,tipo:type}' -o table --only-show-errors
if (-not $Apply) {
    Write-Host 'Vista previa: agregue -Apply solo después de guardar las evidencias.'
    return
}
& az group delete -n $ResourceGroup --yes --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Azure no confirmó la eliminación del grupo.' }
$exists = (& az group exists -n $ResourceGroup --only-show-errors).Trim()
if ($exists -ne 'false') { throw 'El grupo sigue visible; compruebe el estado de eliminación.' }
Write-Host "Grupo $ResourceGroup eliminado."

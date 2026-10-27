param([string]$Name = 'LumeBox-SourceMaker')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
    python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed; build stopped' }
    $runtimeAsset = Join-Path $PSScriptRoot 'runtime.js'
    $pythonAsset = Join-Path $PSScriptRoot 'python_runtime.py'
    $catAsset = Join-Path $PSScriptRoot 'cat_runtime.cjs'
    $htmlAsset = Join-Path $PSScriptRoot 'html_rules.js'
    $actionsAsset = Join-Path $PSScriptRoot 'page_actions.js'
    python -m PyInstaller --noconfirm --clean --onefile --windowed --name $Name --collect-all webview --collect-all playwright --collect-all patchright --collect-all browserforge --collect-all apify_fingerprint_datapoints --collect-all curl_cffi --collect-all selenium --collect-all scrapy --collect-all scrapling --collect-all tld --recursive-copy-metadata scrapling --recursive-copy-metadata scrapy --copy-metadata lxml --hidden-import webview.platforms.edgechromium --add-data "$runtimeAsset;." --add-data "$pythonAsset;." --add-data "$catAsset;." --add-data "$htmlAsset;." --add-data "$actionsAsset;." --distpath '../../build/source-maker' --workpath '../../build/source-maker-work' --specpath '../../build/source-maker-work' app.py
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
    Copy-Item -LiteralPath README.md -Destination ../../build/source-maker/README.md -Force
    Copy-Item -LiteralPath '新手使用说明.md' -Destination ../../build/source-maker/新手使用说明.md -Force
    Write-Host "Ready: build/source-maker/$Name.exe"
} finally {
    Pop-Location
}

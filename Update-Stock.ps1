# Hyosung TNC Stock Price & Spandex Trends Auto-Updater Script (PowerShell - Firebase Firestore version)
# This script fetches latest stock price & spandex data, then synchronizes it with Firebase.

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  Spandex Trends Firebase Real-time Sync Starting" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# A. Helper function to check internet connection quickly
function Test-InternetConnection {
    $testUrls = @("https://www.naver.com", "https://www.google.com")
    foreach ($url in $testUrls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                return $true
            }
        } catch {}
    }
    return $false
}

Write-Host "[1/3] Checking internet connection..." -ForegroundColor Cyan
if (-not (Test-InternetConnection)) {
    Write-Host " [!] Offline state detected. Waiting for connection (max 10s)..." -ForegroundColor Yellow
    $isOnline = $false
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 2
        if (Test-InternetConnection) {
            $isOnline = $true
            break
        }
    }
    if (-not $isOnline) {
        Write-Host " [x] Internet connection failed: Exiting program." -ForegroundColor Red
        exit
    }
}
Write-Host " [o] Internet connection verified!" -ForegroundColor Green

# B. Read Firebase configuration from firebase_config.js
$configPath = Join-Path $PSScriptRoot "firebase_config.js"
if (-not (Test-Path $configPath)) {
    Write-Host " [x] Error: firebase_config.js not found!" -ForegroundColor Red
    exit
}

$configContent = Get-Content -Path $configPath -Encoding UTF8 | Out-String
$projectId = ""

if ($configContent -match 'projectId:\s*["'']([^"'']+)["'']') { $projectId = $Matches[1] }

if (-not $projectId -or $projectId -like "*your-project-id*") {
    Write-Host " [!] Warning: Firebase config is not completed or contains default values." -ForegroundColor Yellow
    Write-Host "   Please open [firebase_config.js](file://$configPath) and" -ForegroundColor Yellow
    Write-Host "   enter your actual Firebase projectId." -ForegroundColor Yellow
    exit
}

# C. Scrape live data from internet
Write-Host "[2/3] Collecting real-time market data..." -ForegroundColor Cyan

$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# Function to fetch SunSirs content handling the WAF cookie challenge
function Get-SunSirsContent {
    param ([string]$url)
    try {
        $resp = Invoke-WebRequest -Uri $url -UserAgent $userAgent -WebSession $session -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        if ($resp.Content -match 'var _0x2 = "([^"]+)"') {
            $cookieValue = $Matches[1]
            Write-Host "   - SunSirs WAF detected. Generating cookie..." -ForegroundColor Yellow
            $cookie = New-Object System.Net.Cookie('HW_CHECK', $cookieValue, '/', '.sunsirs.com')
            $session.Cookies.Add($cookie)
            $resp2 = Invoke-WebRequest -Uri $url -UserAgent $userAgent -WebSession $session -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            return $resp2.Content
        }
        return $resp.Content
    } catch {
        Write-Host "   [!] SunSirs connection failed ($url): $_" -ForegroundColor Yellow
        return $null
    }
}

# 1. Fetch Naver Stock price (Hyosung TNC)
$naverResponse = $null
try {
    $naverRaw = Invoke-WebRequest -Uri "https://m.stock.naver.com/api/stock/298020/price?pageSize=60&page=1" -UserAgent $userAgent -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
    $naverResponse = $naverRaw.Content | ConvertFrom-Json
    Write-Host "   [o] Hyosung TNC stock price collection complete!" -ForegroundColor Green
} catch {
    Write-Host "   [!] Naver Stock API connection failed: $_" -ForegroundColor Yellow
}

# 2. Fetch SunSirs Spandex News list
$newsHtml = Get-SunSirsContent "https://www.sunsirs.com/uk/news-460-1.html"

$spandexPrice = $null
$spandexInv = $null
$targetDateStr = Get-Date -Format "yyyy-MM-dd"

if ($null -ne $newsHtml) {
    if ($newsHtml -match 'href="([^"]*detail_news-\d+\.html)"[\s\S]*?<span>(\d{4}-\d{2}-\d{2})') {
        $latestUrl = $Matches[1]
        $targetDateStr = $Matches[2]
        
        if ($latestUrl -notmatch '^http') {
            $latestUrl = "https://www.sunsirs.com" + $latestUrl
        }
        
        # Fetch news body
        $articleHtml = Get-SunSirsContent $latestUrl
        if ($null -ne $articleHtml) {
            $plainText = [regex]::Replace($articleHtml, '<[^>]+>', ' ').Trim()
            $plainText = [regex]::Replace($plainText, '\s+', ' ')
            
            $ndash = [char]8211
            $mdash = [char]8212
            $plainText = $plainText.Replace("&ndash;", $ndash).Replace("&mdash;", $mdash).Replace("&nbsp;", " ")
            
            # Parse Spandex Price
            if ($plainText -match '(\d{2},\d{3})\s*RMB/ton') {
                $spandexPrice = [int]($Matches[1].Replace(",", ""))
                Write-Host "   [o] Spandex price collection complete: $spandexPrice RMB/ton" -ForegroundColor Green
            } elseif ($plainText -match '(\d{2},\d{3})\s*RMB') {
                $spandexPrice = [int]($Matches[1].Replace(",", ""))
                Write-Host "   [o] Spandex price collection complete: $spandexPrice RMB/ton" -ForegroundColor Green
            }
            
            # Parse Inventory Days
            $rangePattern = 'inventory\s+level[s]?\s+(?:were|was|of)?\s*(?:maintained|around|is|was|to|at)?\s*(?:within\s+)?(?:a\s+low\s+yet\s+reasonable\s+range\s+of\s+)?(\d{2})\s*[' + $ndash + '-]\s*(\d{2})\s*days'
            if ($plainText -match $rangePattern) {
                $val1 = [double]$Matches[1]
                $val2 = [double]$Matches[2]
                $spandexInv = ($val1 + $val2) / 2
                Write-Host "   [o] Spandex inventory days collection complete (average): $spandexInv days" -ForegroundColor Green
            } elseif ($plainText -match 'inventory\s+(?:level|levels|days|around|of)?\s*(?:around|is|was|to|at)?\s*(\d{2}(?:\.\d)?)\s*days') {
                $spandexInv = [double]$Matches[1]
                Write-Host "   [o] Spandex inventory days collection complete: $spandexInv days" -ForegroundColor Green
            }
        }
    }
}

# D. Generate Week Label Helper
function Get-WeekLabel($dateStr) {
    if ($dateStr -match '^(\d{4})-(\d{2})-(\d{2})') {
        $year = [int]$Matches[1]
        $month = [int]$Matches[2]
        $day = [int]$Matches[3]
        
        $yy = ($year % 100).ToString("00")
        $mm = $month.ToString("00")
        $weekNum = [Math]::Ceiling($day / 7)
        $ju = [char]51452
        return "$yy.$mm.$weekNum$ju"
    }
    return $null
}

# E. Merge updates by document ID
$mergedFields = @{}
$mergedPaths = @{}

# 1. Merge Stock Price Data
if ($null -ne $naverResponse) {
    $reversedResponse = @()
    for ($i = $naverResponse.Count - 1; $i -ge 0; $i--) {
        $reversedResponse += $naverResponse[$i]
    }

    $weeklyStockMap = [ordered]@{}
    foreach ($item in $reversedResponse) {
        if ($item.localTradedAt) {
            $label = Get-WeekLabel $item.localTradedAt
            if ($null -ne $label) {
                $priceStr = $item.closePrice.ToString().Replace(",", "")
                $price = 0
                if ([int]::TryParse($priceStr, [ref]$price)) {
                    $weeklyStockMap[$label] = $price
                }
            }
        }
    }

    foreach ($label in $weeklyStockMap.Keys) {
        $stockPrice = $weeklyStockMap[$label]
        if (-not $mergedFields.ContainsKey($label)) {
            $mergedFields[$label] = @{}
            $mergedPaths[$label] = @()
        }
        # integerValue is sent as string in Firestore JSON payload
        $mergedFields[$label]["stock"] = @{ integerValue = [string]$stockPrice }
        if ($mergedPaths[$label] -notcontains "stock") { $mergedPaths[$label] += "stock" }
    }
}

# 2. Merge Spandex Price & Inventory Data
if ($null -ne $spandexPrice -or $null -ne $spandexInv) {
    $targetWeekLabel = Get-WeekLabel $targetDateStr
    if ($null -ne $targetWeekLabel) {
        if (-not $mergedFields.ContainsKey($targetWeekLabel)) {
            $mergedFields[$targetWeekLabel] = @{}
            $mergedPaths[$targetWeekLabel] = @()
        }
        if ($null -ne $spandexPrice) {
            $mergedFields[$targetWeekLabel]["price"] = @{ integerValue = [string]$spandexPrice }
            if ($mergedPaths[$targetWeekLabel] -notcontains "price") { $mergedPaths[$targetWeekLabel] += "price" }
        }
        if ($null -ne $spandexInv) {
            $mergedFields[$targetWeekLabel]["inventory"] = @{ doubleValue = [double]$spandexInv }
            if ($mergedPaths[$targetWeekLabel] -notcontains "inventory") { $mergedPaths[$targetWeekLabel] += "inventory" }
        }
    }
}

# F. Push changes to Firebase Firestore via Commit endpoint (single batch request)
Write-Host "[3/3] Syncing data with Firebase Firestore..." -ForegroundColor Cyan

$writes = @()
foreach ($label in $mergedFields.Keys) {
    $writeItem = @{
        update = @{
            name = "projects/$projectId/databases/(default)/documents/spandex_trends/$label"
            fields = $mergedFields[$label]
        }
        updateMask = @{
            fieldPaths = $mergedPaths[$label]
        }
    }
    $writes += $writeItem
}

if ($writes.Count -gt 0) {
    $bodyObj = @{
        writes = $writes
    }
    $bodyJson = ConvertTo-Json $bodyObj -Compress -Depth 10
    
    $headers = @{
        "Content-Type" = "application/json"
    }
    
    $uri = "https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents:commit"
    
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bodyJson -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        Write-Host " [o] Successfully synchronized $($writes.Count) weekly records to Firebase Firestore!" -ForegroundColor Green
    } catch {
        Write-Host " [x] Firebase Firestore synchronization failed: $_" -ForegroundColor Red
        if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $errBody = $reader.ReadToEnd()
            Write-Host "   Detail error: $errBody" -ForegroundColor Red
        }
    }
} else {
    Write-Host " [o] All data is already up-to-date." -ForegroundColor Green
}

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  Synchronization complete!" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

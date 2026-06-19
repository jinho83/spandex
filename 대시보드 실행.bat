@echo off
chcp 65001 > nul
title 스판덱스 동향 대시보드 실행기

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Stock.ps1"

start "" "%~dp0스판덱스 현황.html"

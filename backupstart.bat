@echo off
powershell -sta -ExecutionPolicy Unrestricted "$s=[scriptblock]::create((gc \"%~f0\"|?{$_.readcount -gt 2})-join\"`n\");&$s" %*&goto:eof
# 指定したサブクライアントバックアップを実行するスクリプト
#
# 参考資料
#  https://documentation.commvault.com/11.24/expert/49164_rest_api_post_subclient_backup.html
#  https://api.commvault.com/#087b8946-c119-455b-abbe-45767509e219


## CommVaultにログインするユーザ設定
# Commvaultのローカルユーザでログインする場合
#$restapiuser="admin"
# Commvault側でAD連携しており、いまログインしているユーザでCommvaultにログインできる場合
$restapiuser=$env:USERDOMAIN+"\"+$env:USERNAME

## パスワードをスクリプト内に直接記載しないよう
# 初回実行時にパスワードを専用保存ファイルに保存する機能
#  なお、パスワードを直接記述したい場合は$restapipasswd に文字列を入れる
$authfile=$PSScriptRoot+".\backupstart.cred"
if((Test-Path $authfile) -eq $false){
    $creds = Get-Credential -UserName $restapiuser -Message $($restapiuser+"ユーザのパスワードを入力してください")
    $creds.Password | ConvertFrom-SecureString | Set-Content -Path $authfile | Out-Null
    $restapipasswd=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($creds.Password))
}else{
    $restapipasswd=[Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($(Get-Content $authfile | ConvertTo-SecureString)))
}
#$restapipasswd=""


## アクセス先のCommvault URL設定
# 旧来のドキュメントだとポート81を使ってるけど
# api.commvaultを見るとwebconsole/apiを使ってる
# 違いについての記述
#   https://documentation.commvault.com/11.24/expert/45592_available_web_services_for_rest_api.html
#$restapiurlbase="http://<CommServe>:81/SearchSvc/CVWebService.svc/"
$restapiurlbase="http://<CommServe>/webconsole/api/"

## バックアップ対象についての記述
#  "名称ベースでジョブを投入する場合"は全部必要
#  "JobIDベースでジョブを投入する場合"は$clientname と $subclientName が必要
# なお、Commvault V11SP24時点では名称ベースの実行時に日本語文字列が使えない
# その場合はJobIDベースのほうで実行すること

# Commvaultの[Client Computers]に表示されるクライアント名での指定
# クライアント名を指定する場合
#$clientname="clientcomputer01"
# 環境変数のCOMPUTERNAMEを利用する場合
#$clientname=$env:COMPUTERNAME
# 環境変数のCOMPUTERNAMEは大文字なので、それを小文字にする場合
$clientname=$($env:COMPUTERNAME).ToLower()

$appName="File System"
$backupsetName="defaultBackupSet"
$subclientName="default"
#$subclientName="テスト"

## バックアップレベルの設定
#  GUI上では設定できなくなったincr+合成がV11SP24時点で使用できる
#$backuplevel="backupLevel=Full" # フルバックアップ
#$backuplevel="backupLevel=Synthetic_Full&runIncrementalBackup=False" # 合成バックアップ のみ
$backuplevel="backupLevel=Synthetic_Full&runIncrementalBackup=true&incrementalLevel=BEFORE_SYNTH" # incrバックアップした後に合成バックアップ
#$backuplevel="backupLevel=Incremental" # incrバックアップ

## バックアップ終了確認間隔
#  ジョブ終了したかの監視間隔(秒)
$sleepwait=10

### ここから実際の操作 ####
#
## CommCell環境にログイン
#  CommVault Event Viewer上で「User [xxx] has logged on. Machine:[Unknown].Locale:[Unknown].」と記録される
#  なお、上記のUnknownに適切な文字列を入れる手法は不明(ドキュメント上に記載なし)
$restapipasswdbase64=[Convert]::ToBase64String(([System.Text.Encoding]::Default).GetBytes($restapipasswd))
$headers=@{
    "Accept"="application/json"
    "Content-Type"="application/json"
}

$loginReq = @{
    username=$restapiuser
    password=$restapipasswdbase64
}

try{
    $loginresponse=Invoke-RestMethod -Method post -Uri $($restapiurlbase+"Login") -Headers $headers -Body $($loginReq|ConvertTo-Json) -ContentType 'application/json'
} catch {
    # Commvaultへの接続失敗時はすぐに分かるので、ユーザが自分でシャットダウンする想定
    Write-Host "Commvaultサーバ への接続に失敗しました"
    exit 1
}



## 指定クライアントのサブクライアント一覧取得
$headers=@{
    "Accept"="application/json"
    "Authtoken"=$loginresponse.token
}
$response=Invoke-RestMethod -Method Get -Uri $($restapiurlbase+"Subclient?clientName="+$clientname) -Headers $headers

# $response.subClientProperties.subClientEntity にサブクライアントの情報が入っているが
# 複数のサブクライアントがあると $response.subClientProperties.subClientEntity.subclientName が複数行になるので注意


## 指定クライアントの指定サブクライアントに対してバックアップ開始
$headers=@{
    "Accept"="application/json"
    "Authtoken"=$loginresponse.token
}

# 名称ベースでジョブを投入する場合
#  日本語文字列だと正常に動作しない
#$url=$restapiurlbase+"/Subclient/byName(clientName='"+$clientname+"',appName='"+$appName+"',backupsetName='"+$backupsetName+"',subclientName='"+$subclientName+"')/action/backup?"+$backuplevel
#try {
#    $response2=Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ""
#} catch {
#    Write-Host "バックアップ開始に失敗しました"
#}

# JobIDベースでジョブを投入する場合
#   １つのクライアントに同じサブクライアント名が複数ある場合の動作が怪しいので注意
#   ("File System"と"DB"の下にそれぞれdefaultがある、とか)
$subclientid=""
$response.subClientProperties.subClientEntity | ForEach-Object {
    $subcliententory=$_
    if($subcliententory.subclientName -eq $subclientName){
        $subclientid=$subcliententory.subclientId
    }
 }
$url=$restapiurlbase+"/Subclient/"+$subclientid+"/action/backup?"+$backuplevel
try {
    $response2=Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ""
} catch {
    Write-Host "バックアップ開始に失敗しました"
    exit 1
}

## ジョブの状態を確認
#  ジョブ投入直後だと値が返ってこないことがあるため１回スリープを入れる
Start-Sleep -Seconds $sleepwait
$headers=@{
    "Accept"="application/json"
    "Authtoken"=$loginresponse.token
}
$request=@{
    "jobId"=$response2.jobIds
}
$url=$restapiurlbase+"Job/"+$response2.jobIds

$flag=0
while ($flag -eq 0){
    $response3=Invoke-RestMethod -Method get -Uri $url -Headers $headers
    # $response3.jobs.jobsummary.status の例 "Waiting","Running","Completed"
    # "Killing Pending","Killed","Pending"
    if($response3.jobs.jobsummary.status -eq "Completed"){
        $flag=1
    }elseif($response3.jobs.jobsummary.status -eq "Pending"){
        if($response3.jobs.jobsummary.pendingReason.contains("heck Network ")){
            # ネットワーク接続の問題が出てPendingとなった場合は、ジョブキャンセル
            # なお、状況により"Check Network Connectivity"と"check Network connectivity"の場合があるので共通部分のみ
            $headers=@{
                "Accept"="application/json"
                "Authtoken"=$loginresponse.token
            }
            $jobcancelresponse=Invoke-RestMethod -Method post -Uri $($restapiurlbase+"Job/"+$($response2.jobIds)+"/action/kill") -Headers $headers
            $flag=1
        }
    }
    Write-Host "backup status:" $response3.jobs.jobsummary.status
    Start-Sleep -Seconds $sleepwait
}

## CommCellログアウト
#  なお、ログアウトしてもCommVault Event Viewer上に記録されない。理由は不明。
#  $logoutresponse の応答内容を確認すると「User logged out」と出力されているので
#  実施自体は完了しているはず
$headers=@{
    "Accept"="application/json"
    "Authtoken"=$loginresponse.token
}
$logoutresponse=Invoke-RestMethod -Method post -Uri $($restapiurlbase+"Logout") -Headers $headers

## 完了後行いたい操作
# シャットダウンしたい場合/ただし管理者権限が必要
Stop-Computer -ComputerName localhost
# ログオフ/一般ユーザ権限で可能
logoff

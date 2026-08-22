#Requires -Version 5.1
<#
.SYNOPSIS
    TeraTerm-Macro 用 ホストリスト管理 & パスワードファイル生成 GUI

.DESCRIPTION
    conf/host.list の作成・編集と、ttpmacro.exe 経由での
    パスワードファイル(conf/password.dat)生成をひとつのツールで行うためのものです。
    「ホストリスト」タブと「パスワード作成」タブに分かれています。

    - host.list の暗号化方式(setpassword/getpassword)は TeraTerm Macro 内部の
      非公開仕様のため、このツールでは再実装せず、ttpmacro.exe に
      「パスワードファイル生成.ttl」を実行させることで password.dat を生成します。
      そのため conf/password.dat は既存のログイン用マクロ(getpassword)と
      そのまま互換性があります。
    - 「パスワード作成」タブには、ホストリストのIP・ユーザーの組み合わせを
      重複排除した一覧を表示します(同じ踏み台を複数の行から参照している場合、
      入力は1回で済みます)。パスワード欄はマスク表示され、チェックを入れた
      行だけが生成対象になります。
    - パスワードは画面の一時領域にのみ保持し、host.list には保存しません。
      生成が成功した行は、そのままだと平文パスワードが画面に残り続けて
      しまうため、生成後にパスワード欄とチェックをクリアします。
    - パスワードファイル生成時に一時的に passwordlist.csv (平文)を書き出しますが、
      conf/password.dat の更新を確認できた場合のみ自動で削除します。

    Windows PowerShell + Windows Forms で動作します(Windows専用)。

.NOTES
    このスクリプトは TeraTerm-Macro プロジェクトのルートディレクトリに
    配置して実行してください(conf/host.list 等を相対パスで参照します)。

    [文字コードについて]
    このファイルは意図的に Shift-JIS(CP932)で保存しています。
    Windows PowerShell 5.1(OS付属版)は、BOMの無いスクリプトファイルを
    システムのデフォルトコードページ(日本語Windowsでは Shift-JIS)として
    読み込むため、UTF-8(BOM無し)のまま保存すると日本語部分を正しく
    読み込めず、意図しない動作になります。
    他のプロジェクトファイル(host.list 等)はUTF-8(BOM無し)が必須ですが、
    このファイルだけは仕様が異なるので注意してください。
    ※ PowerShell 7系(pwsh.exe)で実行する場合はUTF-8(BOM無し)がデフォルトの
      解釈になるため、pwshで使う場合はUTF-8(BOM無し)に変換し直す必要があります。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[System.Windows.Forms.Application]::EnableVisualStyles()

# ボタンのクリックなどイベントハンドラ内で例外が発生すると、既定では
# メッセージが一切表示されずに処理だけが止まってしまう(PowerShell +
# Windows Formsでよくある落とし穴)。原因が分かるよう、ハンドラ内で
# 起きた未処理の例外は必ずダイアログに表示するようにする。
[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$ThreadExceptionHandler = {
    param($sender, $e)
    [System.Windows.Forms.MessageBox]::Show(
        "予期しないエラーが発生しました:`r`n`r`n$($e.Exception.GetType().FullName)`r`n$($e.Exception.Message)`r`n`r`n$($e.Exception.StackTrace)",
        '内部エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}
[System.Windows.Forms.Application]::add_ThreadException($ThreadExceptionHandler)
$ErrorActionPreference = 'Stop'

# ============================================================
# パスワード列をマスク表示するための独自DataGridViewカラム
# ============================================================
# DataGridViewには「パスワード用」の列が標準で無いため、
# 表示をマスクし、編集コントロールもマスク付きTextBoxにする
# カスタムセル/カラムをC#で定義する(WinFormsでよく使われる定番パターン)。
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
using System.Drawing;

public class PasswordCell : DataGridViewTextBoxCell
{
    public override Type EditType
    {
        get { return typeof(PasswordEditingControl); }
    }

    protected override void Paint(Graphics graphics, Rectangle clipBounds, Rectangle cellBounds,
        int rowIndex, DataGridViewElementStates cellState, object value, object formattedValue,
        string errorText, DataGridViewCellStyle cellStyle,
        DataGridViewAdvancedBorderStyle advancedBorderStyle, DataGridViewPaintParts paintParts)
    {
        string masked = string.Empty;
        if (value != null)
        {
            string s = value.ToString();
            masked = new string('*', s.Length);
        }
        base.Paint(graphics, clipBounds, cellBounds, rowIndex, cellState, value, masked, errorText,
            cellStyle, advancedBorderStyle, paintParts);
    }
}

public class PasswordEditingControl : TextBox, IDataGridViewEditingControl
{
    private DataGridView dataGridView;
    private bool valueChanged = false;
    private int rowIndex;

    public PasswordEditingControl()
    {
        this.UseSystemPasswordChar = true;
        this.BorderStyle = BorderStyle.None;
    }

    public object EditingControlFormattedValue
    {
        get { return this.Text; }
        set { if (value != null) this.Text = value.ToString(); }
    }

    public object GetEditingControlFormattedValue(DataGridViewDataErrorContexts context)
    {
        return this.Text;
    }

    public void ApplyCellStyleToEditingControl(DataGridViewCellStyle dataGridViewCellStyle)
    {
        this.Font = dataGridViewCellStyle.Font;
        this.ForeColor = dataGridViewCellStyle.ForeColor;
        this.BackColor = dataGridViewCellStyle.BackColor;
    }

    public int EditingControlRowIndex
    {
        get { return rowIndex; }
        set { rowIndex = value; }
    }

    public bool EditingControlWantsInputKey(Keys keyData, bool dataGridViewWantsInputKey)
    {
        return false;
    }

    public void PrepareEditingControlForEdit(bool selectAll)
    {
        if (selectAll) this.SelectAll();
    }

    public bool RepositionEditingControlOnValueChange
    {
        get { return false; }
    }

    public DataGridView EditingControlDataGridView
    {
        get { return dataGridView; }
        set { dataGridView = value; }
    }

    public bool EditingControlValueChanged
    {
        get { return valueChanged; }
        set { valueChanged = value; }
    }

    public Cursor EditingPanelCursor
    {
        get { return base.Cursor; }
    }

    protected override void OnTextChanged(EventArgs e)
    {
        valueChanged = true;
        if (dataGridView != null) dataGridView.NotifyCurrentCellDirty(true);
        base.OnTextChanged(e);
    }
}

public class PasswordColumn : DataGridViewTextBoxColumn
{
    public PasswordColumn() : base()
    {
        this.CellTemplate = new PasswordCell();
    }
}
'@

# ============================================================
# パス定義
# ============================================================
$ScriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfDir          = Join-Path $ScriptDir 'conf'
$HostListPath     = Join-Path $ConfDir   'host.list'
$SettingsPath     = Join-Path $ConfDir   'gui-settings.json'
$PasswordListPath = Join-Path $ScriptDir 'passwordlist.csv'
$PasswordDatPath  = Join-Path $ConfDir   'password.dat'
$GenMacroPath     = Join-Path $ScriptDir 'パスワードファイル生成.ttl'
# 注意: このファイルは意図的にプロジェクトのルートに置く必要がある。
# ttpmacro.exeはgetdirの返す値(≒getdirが参照するディレクトリ)が
# 「実行を指定した.ttlファイル自身の場所」に連動するらしく、この
# マクロをsub配下などに移動すると、内部で組み立てるconf/password.dat・
# passwordlist.csvのパスがルート直下からずれてしまい、
# 「CSVファイルが見つからない」等のエラーになることを実機で確認済み。

$ColumnDefs = @(
    @{ Name = '表示名';         Header = '表示名' }
    @{ Name = 'ホスト名';       Header = 'ホスト名' }
    @{ Name = 'IP1';           Header = 'ログインIP①' }
    @{ Name = 'OS1';           Header = 'OS種別①' }
    @{ Name = 'User1';         Header = 'ログインユーザ①' }
    @{ Name = 'IP2';           Header = 'ログインIP②' }
    @{ Name = 'OS2';           Header = 'OS種別②' }
    @{ Name = 'User2';         Header = 'ログインユーザ②' }
)

$HostListHeaderLine = '#表示名' + "`t" + 'ホスト名' + "`t" + 'ログインIP①' + "`t" + 'OS種別①' + "`t" + `
    'ログインユーザ①' + "`t" + 'ログインIP②' + "`t" + 'OS種別②' + "`t" + 'ログインユーザ②'

# ============================================================
# 設定(ttpmacro.exeのパス)の読み込み/保存
# ============================================================
function Get-Settings {
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $json = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
            $obj = $json | ConvertFrom-Json
            if ($null -ne $obj -and $obj.PSObject.Properties.Name -contains 'TTPMacroPath') {
                return [string]$obj.TTPMacroPath
            }
        } catch {
            # 壊れている場合は既定値にフォールバック
        }
    }
    # 初回起動時などまだ設定が無い場合の既定パス
    return 'C:\Program Files\teraterm5\ttpmacro.exe'
}

function Set-Settings([string]$ttpmacroPath) {
    if (-not (Test-Path -LiteralPath $ConfDir)) {
        New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
    }
    $obj = [PSCustomObject]@{ TTPMacroPath = $ttpmacroPath }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SettingsPath, ($obj | ConvertTo-Json), $enc)
}

# ============================================================
# host.list の読み込み/書き込み
# ============================================================
function New-HostTable {
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('_RowId', [string])
    foreach ($def in $ColumnDefs) {
        [void]$table.Columns.Add($def.Name, [string])
    }
    # DataTable は IEnumerable を実装しているため、素の return だと
    # PowerShell のパイプラインが行単位に展開してしまう(0行なら $null になる)。
    # -NoEnumerate で DataTable そのものを1オブジェクトとして返す。
    Write-Output -NoEnumerate $table
}

function Import-HostList {
    $table = New-HostTable

    if (Test-Path -LiteralPath $HostListPath) {
        $lines = [System.IO.File]::ReadAllLines($HostListPath, (New-Object System.Text.UTF8Encoding($false)))
        foreach ($line in $lines) {
            if ($line.Trim().Length -eq 0) { continue }              # 完全な空行はスキップ
            if ($line.TrimStart().StartsWith('#')) { continue }       # コメント行(ヘッダ含む)はスキップ

            $cols = $line -split "`t"
            $row = $table.NewRow()
            $row['_RowId'] = [guid]::NewGuid().ToString()
            for ($i = 0; $i -lt $ColumnDefs.Count; $i++) {
                $row[$ColumnDefs[$i].Name] = if ($i -lt $cols.Count) { $cols[$i] } else { '' }
            }
            [void]$table.Rows.Add($row)
        }
    }

    # 同様に DataTable の展開を防ぐため -NoEnumerate で返す
    Write-Output -NoEnumerate $table
}

function Export-HostList([System.Data.DataTable]$table) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($HostListHeaderLine)
    [void]$sb.Append("`r`n")

    foreach ($row in $table.Rows) {
        $values = foreach ($def in $ColumnDefs) { [string]$row[$def.Name] }
        $joined = ($values -join "`t")
        if ($joined.Trim().Length -eq 0) { continue }   # 完全な空行は書き出さない
        [void]$sb.Append($joined)
        [void]$sb.Append("`r`n")
    }

    if (-not (Test-Path -LiteralPath $ConfDir)) {
        New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)   # BOM無しUTF-8
    [System.IO.File]::WriteAllText($HostListPath, $sb.ToString(), $enc)
}

# ============================================================
# パスワード作成タブ用: IP+ユーザーの重複排除一覧
# ============================================================
function New-CredentialTable {
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('Key', [string])
    [void]$table.Columns.Add('Selected', [bool])
    [void]$table.Columns.Add('IP', [string])
    [void]$table.Columns.Add('User', [string])
    [void]$table.Columns.Add('Password', [string])
    Write-Output -NoEnumerate $table
}

# ホストリスト(host.list)のIP①/ユーザー①、IP②/ユーザー②から
# 重複を除いた一覧を作る。既存の一覧(あれば)からチェック状態と
# パスワードを引き継ぐ。
function Build-CredentialTable {
    $previous = @{}
    if ($null -ne $script:CredentialTable) {
        foreach ($prow in $script:CredentialTable.Rows) {
            $pkey = [string]$prow['Key']
            $previous[$pkey] = @{
                Selected = [bool]$prow['Selected']
                Password = [string]$prow['Password']
            }
        }
    }

    $table = New-CredentialTable
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($row in $script:HostTable.Rows) {
        foreach ($pair in @(@('IP1', 'User1'), @('IP2', 'User2'))) {
            $ip = ([string]$row[$pair[0]]).Trim()
            $user = ([string]$row[$pair[1]]).Trim()
            if ($ip.Length -eq 0 -or $user.Length -eq 0) { continue }

            # 注意: "$ip___$user" と書くと、PowerShellの文字列展開では
            # アンダースコアも変数名の一部とみなされるため "$ip___" が
            # 存在しない変数として空文字列に解決されてしまい、結果的に
            # 全ての行が同じキー(ユーザー名のみ)になってしまう。
            # ${ip} のように波括弧で変数名を区切って展開する。
            $key = "${ip}___${user}"
            if ($seen.Contains($key)) { continue }
            [void]$seen.Add($key)

            $newRow = $table.NewRow()
            $newRow['Key'] = $key
            $newRow['IP'] = $ip
            $newRow['User'] = $user
            if ($previous.ContainsKey($key)) {
                $newRow['Selected'] = $previous[$key].Selected
                $newRow['Password'] = $previous[$key].Password
            } else {
                $newRow['Selected'] = $false
                $newRow['Password'] = ''
            }
            [void]$table.Rows.Add($newRow)
        }
    }

    Write-Output -NoEnumerate $table
}

# ============================================================
# フォーム構築
# ============================================================
# 空の入れ物(パネル/タブ/グリッド)を先に親へ追加してDock/サイズを
# 確定させてから、その中身のコントロールを追加する。
# (Anchorに'Right'等を含むコントロールは、追加した時点の親の幅を基準に
#  端からの距離を固定してしまうため、先に子を詰めてから親を追加する順序だと
#  誤った位置に描画されてしまう不具合があったための対策)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'TeraTerm ホストリスト & パスワードファイル管理'
$form.Size = New-Object System.Drawing.Size(1040, 680)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 560)

$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'
$pnlTop.Height = 60
$pnlTop.Padding = New-Object System.Windows.Forms.Padding(8)

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = 'Fill'

$form.Controls.Add($tabControl)   # Fillを先に追加
$form.Controls.Add($pnlTop)       # Topをあとから追加

# ---- 上部: TeraTerm(ttpmacro.exe)設定 ----
$lblTtp = New-Object System.Windows.Forms.Label
$lblTtp.Text = 'ttpmacro.exe のパス:'
$lblTtp.AutoSize = $true
$lblTtp.Location = New-Object System.Drawing.Point(10, 18)

$txtTtp = New-Object System.Windows.Forms.TextBox
$txtTtp.Location = New-Object System.Drawing.Point(150, 15)
$txtTtp.Width = 650
$txtTtp.Anchor = 'Top,Left,Right'
$txtTtp.Text = Get-Settings

$btnBrowseTtp = New-Object System.Windows.Forms.Button
$btnBrowseTtp.Text = '参照...'
$btnBrowseTtp.Location = New-Object System.Drawing.Point(810, 13)
$btnBrowseTtp.Width = 90
$btnBrowseTtp.Anchor = 'Top,Right'

# ttpmacro.exe をファイル選択ダイアログで選ばせ、選択されれば
# テキストボックスと設定ファイルを更新する。選択されればtrueを返す。
function Show-TtpMacroPicker {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'ttpmacro.exe を選択してください'
    $dlg.Filter = 'ttpmacro.exe|ttpmacro.exe|実行ファイル (*.exe)|*.exe|すべてのファイル (*.*)|*.*'

    $currentDir = ''
    if ($txtTtp.Text.Trim().Length -gt 0) {
        $currentDir = Split-Path -Parent $txtTtp.Text
    }
    if ($currentDir.Length -gt 0 -and (Test-Path -LiteralPath $currentDir -PathType Container)) {
        $dlg.InitialDirectory = $currentDir
    } elseif (Test-Path -LiteralPath 'C:\Program Files\teraterm5' -PathType Container) {
        $dlg.InitialDirectory = 'C:\Program Files\teraterm5'
    } elseif (Test-Path -LiteralPath 'C:\Program Files (x86)\teraterm' -PathType Container) {
        $dlg.InitialDirectory = 'C:\Program Files (x86)\teraterm'
    } elseif (Test-Path -LiteralPath 'C:\Program Files' -PathType Container) {
        $dlg.InitialDirectory = 'C:\Program Files'
    }

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtTtp.Text = $dlg.FileName
        Set-Settings -ttpmacroPath $txtTtp.Text
        return $true
    }
    return $false
}

$btnBrowseTtp.Add_Click({ [void](Show-TtpMacroPicker) })

$pnlTop.Controls.AddRange(@($lblTtp, $txtTtp, $btnBrowseTtp))

# ---- タブ1: ホストリスト ----
$tabHost = New-Object System.Windows.Forms.TabPage
$tabHost.Text = 'ホストリスト'
$tabControl.TabPages.Add($tabHost)

$pnlHostRight = New-Object System.Windows.Forms.Panel
$pnlHostRight.Dock = 'Right'
$pnlHostRight.Width = 130
$pnlHostRight.Padding = New-Object System.Windows.Forms.Padding(8)

$gridHost = New-Object System.Windows.Forms.DataGridView
$gridHost.Dock = 'Fill'
$gridHost.AllowUserToAddRows = $false
$gridHost.AllowUserToDeleteRows = $false
$gridHost.AutoGenerateColumns = $true
$gridHost.SelectionMode = 'FullRowSelect'
$gridHost.MultiSelect = $false
$gridHost.RowHeadersWidth = 30

$tabHost.Controls.Add($gridHost)      # Fillを先に追加
$tabHost.Controls.Add($pnlHostRight)  # Rightをあとから追加

function New-SideButton([string]$text, [int]$top) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = 110
    $b.Height = 32
    $b.Location = New-Object System.Drawing.Point(4, $top)
    return $b
}

$btnAdd    = New-SideButton '行を追加'     8
$btnDelete = New-SideButton '行を削除'     46
$btnUp     = New-SideButton '上へ移動'     92
$btnDown   = New-SideButton '下へ移動'     130
$btnReload = New-SideButton '再読込'       190
$btnSave   = New-SideButton '保存'         228

$pnlHostRight.Controls.AddRange(@($btnAdd, $btnDelete, $btnUp, $btnDown, $btnReload, $btnSave))

# ---- タブ2: パスワード作成 ----
$tabPassword = New-Object System.Windows.Forms.TabPage
$tabPassword.Text = 'パスワード作成'
$tabControl.TabPages.Add($tabPassword)

$pnlCredTop = New-Object System.Windows.Forms.Panel
$pnlCredTop.Dock = 'Top'
$pnlCredTop.Height = 40
$pnlCredTop.Padding = New-Object System.Windows.Forms.Padding(8)

$pnlCredBottom = New-Object System.Windows.Forms.Panel
$pnlCredBottom.Dock = 'Bottom'
$pnlCredBottom.Height = 90
$pnlCredBottom.Padding = New-Object System.Windows.Forms.Padding(8)

$gridCred = New-Object System.Windows.Forms.DataGridView
$gridCred.Dock = 'Fill'
$gridCred.AllowUserToAddRows = $false
$gridCred.AllowUserToDeleteRows = $false
$gridCred.AutoGenerateColumns = $false
$gridCred.SelectionMode = 'CellSelect'
$gridCred.RowHeadersWidth = 30

$tabPassword.Controls.Add($gridCred)       # Fillを先に追加
$tabPassword.Controls.Add($pnlCredBottom)  # Bottomをあとから追加
$tabPassword.Controls.Add($pnlCredTop)     # Topをあとから追加

# ---- タブ2 上部: 説明 + 更新ボタン ----
$lblCredInfo = New-Object System.Windows.Forms.Label
$lblCredInfo.Text = ('ホストリストのIP・ユーザーから一覧を作成します(同じ組み合わせは1件にまとめます)。' +
    'チェックを入れ、パスワードを入力した行だけが生成対象になります。')
$lblCredInfo.AutoSize = $true
$lblCredInfo.Location = New-Object System.Drawing.Point(10, 12)

$btnRefreshCred = New-Object System.Windows.Forms.Button
$btnRefreshCred.Text = 'ホストリストから一覧を更新'
$btnRefreshCred.Location = New-Object System.Drawing.Point(700, 5)
$btnRefreshCred.Width = 190
$btnRefreshCred.Anchor = 'Top,Right'

$pnlCredTop.Controls.AddRange(@($lblCredInfo, $btnRefreshCred))

# ---- タブ2 下部: 生成ボタン + ステータス ----
$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = 'パスワードファイル生成 (conf/password.dat)'
$btnGenerate.Location = New-Object System.Drawing.Point(10, 15)
$btnGenerate.Size = New-Object System.Drawing.Size(260, 40)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = ''
$lblStatus.AutoSize = $false
$lblStatus.Location = New-Object System.Drawing.Point(280, 12)
$lblStatus.Size = New-Object System.Drawing.Size(660, 60)
$lblStatus.Anchor = 'Top,Left,Right'
$lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen

$pnlCredBottom.Controls.AddRange(@($btnGenerate, $lblStatus))

# ---- パスワード作成一覧のカラム(チェック/IP/ユーザー/パスワード) ----
$colSelected = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSelected.DataPropertyName = 'Selected'
$colSelected.HeaderText = '選択'
$colSelected.Width = 50

$colIP = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colIP.DataPropertyName = 'IP'
$colIP.HeaderText = 'IPアドレス / ホスト名'
$colIP.ReadOnly = $true
$colIP.Width = 200

$colUser = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUser.DataPropertyName = 'User'
$colUser.HeaderText = 'ユーザー名'
$colUser.ReadOnly = $true
$colUser.Width = 150

$colPassword = New-Object PasswordColumn
$colPassword.DataPropertyName = 'Password'
$colPassword.HeaderText = 'パスワード'
$colPassword.Width = 220

# AddRange(params DataGridViewColumn[])に対して型がバラバラの要素(Object[])を
# そのまま渡すと、PowerShellが「配列全体を1つ目の要素」として渡そうとして
# 型変換エラーになることがあるため、明示的にDataGridViewColumn[]型の配列に
# してから渡す。
[System.Windows.Forms.DataGridViewColumn[]]$credColumns = @($colSelected, $colIP, $colUser, $colPassword)
$gridCred.Columns.AddRange($credColumns)

# チェックボックス列は既定では他のセルに移動するまで値が確定しないため、
# 値が変わった時点ですぐにコミットするようにする(定番の対処)
$gridCred.Add_CurrentCellDirtyStateChanged({
    if ($gridCred.IsCurrentCellDirty) {
        $gridCred.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

# ============================================================
# データバインド: ホストリスト
# ============================================================
$script:HostTable = Import-HostList
$bindingSource = New-Object System.Windows.Forms.BindingSource
$bindingSource.DataSource = $script:HostTable
$gridHost.DataSource = $bindingSource

function Format-HostGrid {
    if ($gridHost.Columns['_RowId']) {
        $gridHost.Columns['_RowId'].Visible = $false
    }
    foreach ($def in $ColumnDefs) {
        if ($gridHost.Columns[$def.Name]) {
            $gridHost.Columns[$def.Name].HeaderText = $def.Header
        }
    }
    if ($gridHost.Columns['表示名'])   { $gridHost.Columns['表示名'].Width = 110 }
    if ($gridHost.Columns['ホスト名']) { $gridHost.Columns['ホスト名'].Width = 90 }
}
Format-HostGrid

# ============================================================
# データバインド: パスワード作成タブの一覧
# ============================================================
$script:CredentialTable = $null
$script:CredentialTable = Build-CredentialTable
$credBindingSource = New-Object System.Windows.Forms.BindingSource
$credBindingSource.DataSource = $script:CredentialTable
$gridCred.DataSource = $credBindingSource

function Refresh-CredentialList {
    $script:CredentialTable = Build-CredentialTable
    $credBindingSource.DataSource = $script:CredentialTable
}

$btnRefreshCred.Add_Click({ Refresh-CredentialList })

# 「パスワード作成」タブに切り替えたときは自動で最新化する
# (ホストリストタブでの編集を反映させるため)
$tabControl.Add_SelectedIndexChanged({
    if ($tabControl.SelectedTab -eq $tabPassword) {
        Refresh-CredentialList
    }
})

# ============================================================
# ヘルパー: 選択中のホストリスト行を取得
# ============================================================
function Get-SelectedHostRow {
    if ($gridHost.SelectedRows.Count -eq 0) { return $null }
    return $gridHost.SelectedRows[0].DataBoundItem
}

# ============================================================
# 行操作(ホストリストタブ)
# ============================================================
$btnAdd.Add_Click({
    $row = $script:HostTable.NewRow()
    $row['_RowId'] = [guid]::NewGuid().ToString()
    foreach ($def in $ColumnDefs) { $row[$def.Name] = '' }
    [void]$script:HostTable.Rows.Add($row)
})

$btnDelete.Add_Click({
    $rowView = Get-SelectedHostRow
    if ($null -eq $rowView) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        'この行を削除しますか?', '確認',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $rowView.Row.Delete()
    $script:HostTable.AcceptChanges()
})

function Move-SelectedRow([int]$direction) {
    if ($gridHost.SelectedRows.Count -eq 0) { return }
    $rowView = $gridHost.SelectedRows[0].DataBoundItem
    $idx = $script:HostTable.Rows.IndexOf($rowView.Row)
    $newIdx = $idx + $direction
    if ($newIdx -lt 0 -or $newIdx -ge $script:HostTable.Rows.Count) { return }

    # DataRowオブジェクト自体は入れ替えず、値を交換することで
    # 表示順を安全に変更する
    $colCount = $script:HostTable.Columns.Count
    for ($i = 0; $i -lt $colCount; $i++) {
        $tmp = $script:HostTable.Rows[$idx][$i]
        $script:HostTable.Rows[$idx][$i] = $script:HostTable.Rows[$newIdx][$i]
        $script:HostTable.Rows[$newIdx][$i] = $tmp
    }
    $gridHost.ClearSelection()
    $gridHost.Rows[$newIdx].Selected = $true
    $gridHost.CurrentCell = $gridHost.Rows[$newIdx].Cells[1]
}

$btnUp.Add_Click({ Move-SelectedRow(-1) })
$btnDown.Add_Click({ Move-SelectedRow(1) })

$btnReload.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        'host.list を再読込します。保存していない変更は失われます。よろしいですか?', '確認',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $script:HostTable = Import-HostList
    $bindingSource.DataSource = $script:HostTable
    $script:CredentialTable = $null
    Format-HostGrid
    Refresh-CredentialList
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblStatus.Text = 'host.list を再読込しました。'
})

$btnSave.Add_Click({
    try {
        Export-HostList -table $script:HostTable
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblStatus.Text = 'conf/host.list を保存しました。'
    } catch {
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        $lblStatus.Text = "保存に失敗しました: $($_.Exception.Message)"
    }
})

# ============================================================
# パスワードファイル生成
# ============================================================
$btnGenerate.Add_Click({
  try {
    # チェックボックスやパスワード欄を編集した直後にボタンを押した場合に
    # 備え、確定していない編集値を確定させておく
    if ($gridCred.IsCurrentCellDirty -or $gridCred.IsCurrentRowDirty) {
        $gridCred.EndEdit()
    }

    $ttpPath = $txtTtp.Text.Trim()
    if ($ttpPath.Length -eq 0 -or -not (Test-Path -LiteralPath $ttpPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            'ttpmacro.exe のパスが正しく設定されていません。続けて選択ダイアログを開きます。',
            '確認', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if (-not (Show-TtpMacroPicker)) {
            return
        }
        $ttpPath = $txtTtp.Text.Trim()
        if ($ttpPath.Length -eq 0 -or -not (Test-Path -LiteralPath $ttpPath -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show(
                'ttpmacro.exe が選択されなかったため処理を中止しました。',
                'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
    }
    if (-not (Test-Path -LiteralPath $GenMacroPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "パスワードファイル生成.ttl が見つかりません。`r`n($GenMacroPath)",
            'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    # チェックが入っていて、ユーザー・パスワードの両方が揃っている行だけを
    # 生成対象にする(どれか1つでも欠けていれば何もしない=対象外)
    $csvLines = New-Object System.Collections.Generic.List[string]
    $csvLines.Add('# IP, user, password')
    $errorRows = New-Object System.Collections.Generic.List[string]
    $processedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($row in $script:CredentialTable.Rows) {
        $selected = [bool]$row['Selected']
        if (-not $selected) { continue }

        $ip = ([string]$row['IP']).Trim()
        $user = ([string]$row['User']).Trim()
        $pass = [string]$row['Password']
        if ($ip.Length -eq 0 -or $user.Length -eq 0 -or $pass.Length -eq 0) { continue }

        if ($pass.Contains(',')) {
            $errorRows.Add("$ip ($user): パスワードに ',' は使用できません")
        } else {
            $csvLines.Add("$ip,$user,$pass")
            $processedKeys.Add([string]$row['Key'])
        }
    }

    if ($errorRows.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            ("以下のパスワードは使用できません:`r`n" + ($errorRows -join "`r`n")),
            'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    if ($csvLines.Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show(
            ('生成対象がありません。チェックを入れ、ユーザー・パスワードの両方を入力した行だけが' +
             '対象になります。'),
            '確認', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        ("チェックが入った $($processedKeys.Count) 件を passwordlist.csv に一時的に書き出し、" +
         "TeraTermマクロ(ttpmacro)で暗号化してconf/password.dat に保存します。`r`n" +
         "更新を確認できた場合のみ、平文の passwordlist.csv は自動的に削除されます。`r`n続行しますか?"),
        '確認', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        $content = ($csvLines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($PasswordListPath, $content, $enc)

        $btnGenerate.Enabled = $false
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblStatus.Text = 'ttpmacro を実行しています。表示されるダイアログを確認してください...'
        $form.Refresh()

        # password.dat の更新有無をあとで確認するため、実行前の更新日時を控えておく
        $beforeTime = $null
        if (Test-Path -LiteralPath $PasswordDatPath) {
            $beforeTime = (Get-Item -LiteralPath $PasswordDatPath).LastWriteTimeUtc
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ttpPath
        $psi.Arguments = '"' + $GenMacroPath + '"'
        $psi.UseShellExecute = $true
        # ttpmacro の getdir はプロセスのカレントディレクトリを返す仕様。
        # 明示的に指定しないと呼び出し元(このPowerShellプロセス)のカレント
        # ディレクトリを引き継いでしまい、conf/password.dat や
        # passwordlist.csv を正しいパスで見つけられずマクロが期待通り
        # 動かないため、必ずプロジェクトのルートを指定する。
        $psi.WorkingDirectory = $ScriptDir

        # 実際に何を起動しようとしたかをここで必ず可視化する。
        # (ラベルの文字色/文言の変化だけだと見落とされやすいため)
        [System.Windows.Forms.MessageBox]::Show(
            "これから以下の内容でttpmacroを起動します。`r`n`r`n" +
            "exe: $ttpPath`r`n" +
            "macro: $GenMacroPath`r`n" +
            "作業ディレクトリ: $ScriptDir`r`n`r`n" +
            "OKを押すと起動します。マクロが完了する(メッセージボックスが閉じる)まで、`r`n" +
            "このウィンドウは操作できなくなります。",
            '実行内容の確認', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

        $proc = [System.Diagnostics.Process]::Start($psi)

        if ($null -eq $proc) {
            # UseShellExecute=true の場合、既に起動している同じアプリの
            # インスタンスにDDE等で処理が引き継がれ、Process.Startが
            # プロセスを返さない(≒追跡できない)ことがある。
            [System.Windows.Forms.MessageBox]::Show(
                'ttpmacro のプロセスを取得できませんでした(既に起動している別のTeraTermウィンドウに' +
                '処理が引き継がれた可能性があります)。TeraTerm関連のウィンドウをすべて閉じてから' +
                '再度お試しください。',
                'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        $proc.WaitForExit()

        $updated = $false
        if (Test-Path -LiteralPath $PasswordDatPath) {
            $afterTime = (Get-Item -LiteralPath $PasswordDatPath).LastWriteTimeUtc
            if ($null -eq $beforeTime -or $afterTime -gt $beforeTime) {
                $updated = $true
            }
        }

        if ($updated) {
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $lblStatus.Text = "conf/password.dat を更新しました($($processedKeys.Count) 件)。"
            if (Test-Path -LiteralPath $PasswordListPath) {
                Remove-Item -LiteralPath $PasswordListPath -Force -ErrorAction SilentlyContinue
            }
            # 生成に使った行は、平文パスワードを画面に残さないようクリアする
            foreach ($row in $script:CredentialTable.Rows) {
                if ($processedKeys.Contains([string]$row['Key'])) {
                    $row['Password'] = ''
                    $row['Selected'] = $false
                }
            }
            $gridCred.Refresh()
        } else {
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $lblStatus.Text = 'conf/password.dat の更新を確認できませんでした。'
            [System.Windows.Forms.MessageBox]::Show(
                'conf/password.dat の更新日時が変わっていません。ttpmacroのウィンドウが' +
                '裏に隠れて入力待ちになっていないか、タスクバー/タスクマネージャーで' +
                'ttpmacro.exeが起動していないか確認してください。' +
                "`r`n平文の passwordlist.csv は確認のため削除せずに残しています。",
                '確認できませんでした', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    } catch {
        $innerErr = $_
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
        $lblStatus.Text = "パスワードファイル生成に失敗しました: $($innerErr.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "パスワードファイル生成に失敗しました:`r`n`r`n$($innerErr.Exception.GetType().FullName)`r`n$($innerErr.Exception.Message)",
            'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $btnGenerate.Enabled = $true
    }
  } catch {
    $outerErr = $_
    [System.Windows.Forms.MessageBox]::Show(
        "処理中に予期しないエラーが発生しました:`r`n`r`n$($outerErr.Exception.GetType().FullName)`r`n$($outerErr.Exception.Message)",
        'エラー', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  }
})

[void]$form.ShowDialog()

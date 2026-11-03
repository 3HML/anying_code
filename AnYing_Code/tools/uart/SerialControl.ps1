param([switch]$TestOnly,[string]$PreviewPath='')

$ErrorActionPreference = 'Stop'

function Get-Crc8([byte[]]$Data) {

    [int]$crc = 0

    foreach ($v in $Data) {

        $crc = $crc -bxor $v

        for ($i=0; $i -lt 8; $i++) {

            if ($crc -band 128) { $crc = (($crc -shl 1) -bxor 7) -band 255 }

            else { $crc = ($crc -shl 1) -band 255 }

        }

    }

    return [byte]$crc

}

function New-Request([byte]$Sequence,[byte]$Command,[byte]$Argument) {

    [byte[]]$data = @(0xA5,$Sequence,$Command,$Argument,0)

    $data[4] = Get-Crc8 $data[0..3]

    return ,$data

}

function Convert-Reply([byte[]]$Data,[byte]$Sequence,[byte]$Command) {

    if ($Data.Length -ne 15 -or $Data[0] -ne 0x5A) { throw '应答长度或帧头错误。' }

    if ($Data[1] -ne $Sequence -or $Data[2] -ne $Command) { throw '应答编号不匹配，请重新查询状态。' }

    if ((Get-Crc8 $Data[0..13]) -ne $Data[14]) { throw '应答校验失败，请检查USB连接。' }

    if ($Data[13] -notin @(93,113)) { throw '当前固件的状态协议版本不受支持。' }
    $modern=$Data[13] -eq 113
    if ($modern) {
        $count=$Data[6] -band 63; $index=$Data[7] -band 31
        $contrastCode=(($Data[6] -shr 6) -band 3) -bor (($Data[7] -shr 3) -band 4)
        $hours=$Data[8] -band 31; $minutes=$Data[9] -band 63; $seconds=$Data[10] -band 63
        $interval=(($Data[8] -shr 5) -band 7) -bor (($Data[9] -shr 3) -band 24)
        $musicOn=[bool]($Data[4] -band 128)
    } else {
        $count=($Data[6] -shr 3) -band 7; $index=$Data[6] -band 7
        $contrastCode=2; $hours=$Data[7]; $minutes=$Data[8]; $seconds=$Data[9]; $interval=$Data[10]
        $musicOn=[bool]($Data[6] -band 128)
    }

    return [pscustomobject]@{

        Result=[int]$Data[3]; Auto=[bool]($Data[4] -band 1)

        Settings=[bool]($Data[4] -band 2); Sleeping=[bool]($Data[4] -band 4)

        Finite=[bool]($Data[4] -band 8); Thumbnail=[bool]($Data[4] -band 16)

        Visible=[bool]($Data[4] -band 32); Ready=[bool]($Data[4] -band 64)

        Brightness=($Data[5] -shr 4); Volume=($Data[5] -band 15)

        Music=$musicOn; Count=$count; Index=$index
        ContrastCode=$contrastCode; Contrast=($contrastCode-2); ContrastAvailable=$modern
        Hours=[int]$hours; Minutes=[int]$minutes; Seconds=[int]$seconds; Interval=[int]$interval

        Error=($Data[11] -shr 4); State=($Data[11] -band 15)

        FlashError=($Data[12] -shr 4); AudioError=($Data[12] -band 15)

        Version=[int]$Data[13]

    }

}

function Convert-Diagnostic([byte[]]$Data,[byte]$Sequence) {

    if ($Data.Length -ne 15 -or $Data[0] -ne 0x5A -or $Data[1] -ne $Sequence -or $Data[2] -ne 0) { throw '诊断应答不匹配。' }

    if ((Get-Crc8 $Data[0..13]) -ne $Data[14]) { throw '诊断应答校验失败。' }

    if ($Data[3] -ne 0 -or $Data[13] -notin @(99,100)) { throw '当前固件不支持099/100详细诊断页。' }

    return [pscustomobject]@{Context=([int]$Data[4]+256*[int]$Data[5]);State=($Data[6] -band 15);Error=($Data[6] -shr 4);CacheMask=([int]$Data[7] -band 15);Version=[int]$Data[13];IrCommand=[int]$Data[8];IrFrames=[int]$Data[9]}

}

if ($TestOnly) {

    if ((Get-Crc8 ([Text.Encoding]::ASCII.GetBytes('123456789'))) -ne 0xF4) { throw 'CRC vector' }

    [byte[]]$request=New-Request 7 5 3

    if ($request.Length -ne 5 -or $request[4] -ne (Get-Crc8 $request[0..3])) { throw 'Request' }

    [byte[]]$response=@(0x5A,7,5,0,0x61,0x93,0xB2,1,7,0,5,0x34,0x12,93,0)

    $response[14]=Get-Crc8 $response[0..13]

    $state=Convert-Reply $response 7 5

    if ($state.Volume -ne 3 -or $state.Brightness -ne 9 -or $state.Count -ne 6 -or $state.Index -ne 2 -or !$state.Auto -or !$state.Music) { throw 'Decode' }

    $response[14]=$response[14] -bxor 1

    $rejected=$false

    try { $null=Convert-Reply $response 7 5 } catch { $rejected=$true }

    if (!$rejected) { throw 'Bad checksum accepted' }

    [byte[]]$diag=@(0x5A,7,0,0,0x34,0x12,0xB4,9,0,0,0,0,0,99,0)

    $diag[14]=Get-Crc8 $diag[0..13]

    $d=Convert-Diagnostic $diag 7

    if ($d.Context -ne 0x1234 -or $d.State -ne 4 -or $d.Error -ne 11 -or $d.CacheMask -ne 9) { throw 'Diagnostic decode' }

    $diag[13]=100;$diag[8]=0xA2;$diag[9]=7;$diag[14]=Get-Crc8 $diag[0..13]

    $ir=Convert-Diagnostic $diag 7

    if ($ir.IrCommand -ne 0xA2 -or $ir.IrFrames -ne 7 -or $ir.Version -ne 100) { throw 'IR100 diagnostic decode' }

    $diag[14]=$diag[14] -bxor 1

    $rejected=$false;try { $null=Convert-Diagnostic $diag 7 } catch { $rejected=$true };if (!$rejected) { throw 'Diagnostic CRC' }

    $extendedCases=0
    foreach ($n in 0..32) { foreach ($contrast in 0..4) { foreach ($period in @(1,7,8,15,16,30)) {
        foreach ($idx in @(@(0,[Math]::Max(0,$n-1)) | Select-Object -Unique)) {
            [byte[]]$packet=@(0x5A,7,5,0,0xFF,0x96,($n -bor (($contrast -band 3) -shl 6)),($idx -bor (($contrast -band 4) -shl 3)),(24 -bor (($period -band 7) -shl 5)),(59 -bor (($period -shr 3) -shl 6)),59,0x34,0x12,113,0)
            $packet[14]=Get-Crc8 $packet[0..13]
            $v=Convert-Reply $packet 7 5
            if ($v.Count -ne $n -or $v.Index -ne $idx -or $v.ContrastCode -ne $contrast -or $v.Contrast -ne ($contrast-2) -or $v.Interval -ne $period -or $v.Hours -ne 24 -or $v.Minutes -ne 59 -or $v.Seconds -ne 59 -or !$v.Music -or !$v.Auto -or !$v.Settings -or !$v.Sleeping -or !$v.Finite -or !$v.Thumbnail -or !$v.Visible -or !$v.Ready -or $v.Brightness -ne 9 -or $v.Volume -ne 6 -or $v.Error -ne 3 -or $v.State -ne 4 -or $v.FlashError -ne 1 -or $v.AudioError -ne 2) { throw '113 field boundary decode' }
            $extendedCases++
        }
    } } }
    $packet[4]=0;$packet[14]=Get-Crc8 $packet[0..13];$v=Convert-Reply $packet 7 5
    if ($v.Music -or $v.Auto -or $v.Sleeping -or $v.Ready) { throw '113 flags off' }
    $packet[13]=114;$packet[14]=Get-Crc8 $packet[0..13];$rejected=$false
    try { $null=Convert-Reply $packet 7 5 } catch { $rejected=$true }
    if (!$rejected) { throw 'Unknown version accepted' }
    [pscustomobject]@{Passed=$true;Extended113Cases=$extendedCases;Diagnostic=$d;IR=$ir;RequestHex=[BitConverter]::ToString($request);Decoded=$state} | ConvertTo-Json -Depth 3

    exit

}

Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

[Windows.Forms.Application]::EnableVisualStyles()

$script:Port=$null

$script:Sequence=0

$script:State=$null

$script:InFlight=$false

$form=New-Object Windows.Forms.Form

$form.Text='安映 · 多媒体展示终端'

$form.ClientSize=New-Object Drawing.Size(650,460)

$form.StartPosition='CenterScreen'

$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)

$form.FormBorderStyle='FixedDialog'

$form.MaximizeBox=$false

function New-Label($Text,$X,$Y,$W,$H) {

    $l=New-Object Windows.Forms.Label

    $l.Text=$Text;$l.Location=New-Object Drawing.Point($X,$Y);$l.Size=New-Object Drawing.Size($W,$H)

    $form.Controls.Add($l);return $l

}

function New-Button($Text,$X,$Y,$W,$Action) {

    $b=New-Object Windows.Forms.Button

    $b.Text=$Text;$b.Location=New-Object Drawing.Point($X,$Y);$b.Size=New-Object Drawing.Size($W,36)

    $b.Add_Click($Action);$form.Controls.Add($b);return $b

}

$null=New-Label '板载 USB 串口（CH340），115200 / 8N1' 20 16 610 25

$ports=New-Object Windows.Forms.ComboBox

$ports.Location=New-Object Drawing.Point(20,49);$ports.Size=New-Object Drawing.Size(145,30)

$ports.DropDownStyle='DropDownList';$form.Controls.Add($ports)

function Refresh-Ports {

    $ports.Items.Clear()

    foreach ($n in [IO.Ports.SerialPort]::GetPortNames() | Sort-Object) { $null=$ports.Items.Add($n) }

    if ($ports.Items.Count -gt 0) { $ports.SelectedIndex=0 }

}

$refresh=New-Button '刷新端口' 175 46 100 { Refresh-Ports }

$connect=New-Button '连接' 285 46 100 {

    try {

        if ($script:Port -and $script:Port.IsOpen) {

            $script:Port.Close();$script:Port.Dispose();$script:Port=$null

            $connect.Text='连接';$status.Text='已断开。';return

        }

        if (!$ports.SelectedItem) { throw '请先选择CH340对应的COM端口。' }

        $script:Port=New-Object IO.Ports.SerialPort([string]$ports.SelectedItem,115200,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)

        $script:Port.Handshake=[IO.Ports.Handshake]::None

        $script:Port.DtrEnable=$false;$script:Port.RtsEnable=$false

        $script:Port.ReadTimeout=50;$script:Port.WriteTimeout=300

        $script:Port.Open();$connect.Text='断开'

        Send-Command 0 0

    } catch { $status.Text=$_.Exception.Message }

}

$query=New-Button '查询状态' 395 46 110 { Send-Command 0 0 }

$diagnostic=New-Button '详细诊断' 515 46 110 { Send-Command 0 1 }

$info=New-Label '连接后点击“查询状态”。' 20 105 610 122

$info.BackColor=[Drawing.Color]::FromArgb(240,244,248)

$manual=New-Button '手动模式' 20 246 125 { Send-Command 2 0 }

$auto=New-Button '自动轮播' 155 246 125 { Send-Command 2 1 }

$next=New-Button '下一张图片' 290 246 150 { Send-Command 1 0 }

$music=New-Button '开启音乐' 20 296 125 {

    if (!$script:State) { $status.Text='请先查询当前状态。';return }

    $a=1;if ($script:State.Music) { $a=0 }

    Send-Command 3 $a

}

$song=New-Button '下一首歌曲' 155 296 125 { Send-Command 4 0 }

$null=New-Label '音量' 300 302 50 25

$volume=New-Object Windows.Forms.NumericUpDown

$volume.Location=New-Object Drawing.Point(350,299);$volume.Size=New-Object Drawing.Size(65,30)

$volume.Minimum=0;$volume.Maximum=9;$volume.Value=9;$form.Controls.Add($volume)

$setVolume=New-Button '应用音量' 430 296 115 { Send-Command 5 ([byte]$volume.Value) }

$null=New-Label '参数页、睡眠、缩略图和切换期间以本地操作为先。音量应用后即时生效。' 20 352 610 42

$status=New-Label '就绪。一次发送一条命令；超时后不会自动重发切图或切歌。' 20 404 610 42

function Show-State($S) {

    $mode='手动';if ($S.Auto) { $mode='自动' }

    $page='浏览';if ($S.Settings) { $page='设置' } elseif ($S.Sleeping) { $page='睡眠' } elseif ($S.Thumbnail) { $page='缩略图' }

    $songText='0/0';if ($S.Count -gt 0) { $songText=('{0}/{1}' -f ($S.Index+1),$S.Count) }

    $musicText='关闭';if ($S.Music) { $musicText='开启' }

    $time='不限时';if ($S.Finite) { $time=('{0:00}:{1:00}:{2:00}' -f $S.Hours,$S.Minutes,$S.Seconds) }

    $contrastText='—';if ($S.ContrastAvailable) { $contrastText=('{0:+0;-0;0}' -f $S.Contrast) }
    $info.Text="模式：$mode   页面：$page   轮播周期：$($S.Interval) 秒`r`n亮度：$($S.Brightness)   对比度：$contrastText   音量：$($S.Volume)`r`n音乐：$musicText   曲目：$songText   剩余时间：$time`r`n状态码：$($S.State)   读卡错误：$($S.Error)   音频错误：$($S.AudioError)   配置错误：$($S.FlashError)"

    $music.Text=if ($S.Music) { '关闭音乐' } else { '开启音乐' }

    $volume.Value=[Math]::Min(9,$S.Volume)

}

function Send-Command([byte]$Command,[byte]$Argument) {

    if ($script:InFlight) { return }

    if (!$script:Port -or !$script:Port.IsOpen) { $status.Text='请先连接串口。';return }

    $script:InFlight=$true

    try {

        $script:Sequence=($script:Sequence+1) -band 255

        [byte[]]$packet=New-Request $script:Sequence $Command $Argument

        $script:Port.DiscardInBuffer()

        $script:Port.Write($packet,0,$packet.Length)

        [byte[]]$reply=New-Object byte[] 15

        $count=0;$watch=[Diagnostics.Stopwatch]::StartNew()

        while ($count -lt 15 -and $watch.ElapsedMilliseconds -lt 800) {

            try { $v=$script:Port.ReadByte() } catch [TimeoutException] { continue }

            if ($count -eq 0 -and $v -ne 0x5A) { continue }

            $reply[$count]=[byte]$v;$count++

        }

        if ($count -ne 15) { throw '等待应答超时。请确认设备正常运行、选择正确端口；先查询状态再决定是否重试。' }

        if ($Command -eq 0 -and $Argument -eq 1) {

            $d=Convert-Diagnostic $reply $script:Sequence

            $status.Text=('诊断：状态{0:X1} 错误{1:X1} 上下文{2:X4} 缓存{3:X1}；红外码{4:X2} 帧计数{5}' -f $d.State,$d.Error,$d.Context,$d.CacheMask,$d.IrCommand,$d.IrFrames)

            return

        }

        $script:State=Convert-Reply $reply $script:Sequence $Command

        Show-State $script:State

        $messages=@('已受理；查询显示的是采样时状态，切图/切歌完成可再次查询。','不支持此命令。','参数超出范围。','设备忙：请结束本地操作、退出设置/睡眠/缩略图后重试。','未发现可播放歌曲。','请求校验失败。')

        if ($script:State.Result -lt $messages.Count) { $status.Text=$messages[$script:State.Result] }

        else { $status.Text='未知应答状态：'+$script:State.Result }

    } catch { $status.Text=$_.Exception.Message }

    finally { $script:InFlight=$false }

}

$form.Add_FormClosed({if ($script:Port) { $script:Port.Dispose() }})

Refresh-Ports

if ($PreviewPath) {

    [byte[]]$sample=@(0x5A,1,0,0,0xE1,0x96,0xA0,31,0xA0,42,15,0x01,0x00,113,0)

    $sample[14]=Get-Crc8 $sample[0..13]

    Show-State (Convert-Reply $sample 1 0)

    $status.Text='界面预览：示例状态，未连接设备。'

    $form.ShowInTaskbar=$false; $form.Opacity=0; $form.Show(); [Windows.Forms.Application]::DoEvents()

    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)

    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))

    $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)

    $bitmap.Dispose();$form.Dispose()

    exit

}

[void]$form.ShowDialog()


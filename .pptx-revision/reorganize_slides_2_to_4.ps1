Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_修订.pptx'
$destination = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_三部分版.pptx'

if (-not (Test-Path -LiteralPath $source)) { throw "Source PPTX not found: $source" }
if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }

function Get-ShapeText([System.Xml.XmlElement]$shape, [System.Xml.XmlNamespaceManager]$manager) {
    return (($shape.SelectNodes('.//a:t', $manager) | ForEach-Object { $_.InnerText }) -join '')
}

function Set-ShapeText([System.Xml.XmlElement]$shape, [string]$text, [System.Xml.XmlNamespaceManager]$manager) {
    $textNodes = @($shape.SelectNodes('.//a:t', $manager))
    if ($textNodes.Count -eq 0) { throw "The target shape has no editable text run." }
    $textNodes[0].InnerText = $text
    foreach ($node in $textNodes | Select-Object -Skip 1) { $node.InnerText = '' }
}

function Set-ShapeFrame([System.Xml.XmlElement]$shape, [int64]$x, [int64]$y, [int64]$cx, [int64]$cy, [System.Xml.XmlNamespaceManager]$manager) {
    $off = $shape.SelectSingleNode('./p:spPr/a:xfrm/a:off', $manager)
    $ext = $shape.SelectSingleNode('./p:spPr/a:xfrm/a:ext', $manager)
    if ($null -eq $off -or $null -eq $ext) { throw "The target shape has no transform frame." }
    $off.SetAttribute('x', [string]$x); $off.SetAttribute('y', [string]$y)
    $ext.SetAttribute('cx', [string]$cx); $ext.SetAttribute('cy', [string]$cy)
}

function Find-Shape([System.Xml.XmlDocument]$doc, [string]$text, [System.Xml.XmlNamespaceManager]$manager) {
    $hits = @($doc.SelectNodes('//p:sp', $manager) | Where-Object { (Get-ShapeText $_ $manager) -eq $text })
    if ($hits.Count -ne 1) { throw "Expected one shape with text [$text], found $($hits.Count)." }
    return $hits[0]
}

function Update-Slide2([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$manager) {
    $changes = [ordered]@{
        '赛题要求与项目目标' = '赛题预期成果'
        '项目路线：先完成必须的 HDMI 多媒体系统，再叠加扩展功能，最后在同一工程中实现音游。' = '项目以赛题基础要求为底座，叠加扩展功能，并拓展为 FPGA 音游。'
        '基础要求｜必须完成' = '基础要求'
        '图片读取、显示与切换' = '基础多媒体播放'
        'TF 卡 BMP → SDRAM 帧缓存 → HDMI；支持手动切图与自动轮播。' = 'TF 卡 BMP 读取、SDRAM 帧缓存、HDMI 显示、手动切图与自动轮播。'
        'HDMI 音频与音视频播放' = 'HDMI 音频输出'
        '按赛题规格输出 48 kHz 音频，与画面形成完整多媒体演示。' = '输出 48 kHz PCM 音频，与图片显示共同构成音视频播放系统。'
        '项目最终目标' = '扩展要求'
        '在多媒体底座上完成四轨音游' = '图像处理与音频可视化'
        'SD 卡读取谱面与 PCM 音频，音乐时间驱动音符下落和判定。' = '双线性缩放适配不同分辨率 BMP。'
        '实现 Tap / Hold、暂停重开、计分结算和 HDMI 游戏 HUD。' = '亮度、对比度调节与 OSD 参数显示。'
        '游戏与图片、普通音乐媒体模式集成在同一系统中。' = 'FFT 频谱与视频画面叠加显示。'
    }
    foreach ($old in $changes.Keys) { Set-ShapeText (Find-Shape $doc $old $manager) $changes[$old] $manager }

    $copySource = Find-Shape $doc 'TF 卡 BMP 读取、SDRAM 帧缓存、HDMI 显示、手动切图与自动轮播。' $manager
    $audioGame = $copySource.CloneNode($true)
    Set-ShapeText $audioGame '音游：加载 GAME.BIN 与 GAME.WAV，完成四轨 Tap / Hold 判定、计分结算和 HDMI 游戏 HUD。' $manager
    Set-ShapeFrame $audioGame 800100 5334000 10591800 400050 $manager
    $spTree = $doc.SelectSingleNode('//p:spTree', $manager)
    [void]$spTree.AppendChild($audioGame)
}

function Update-Slide3([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$manager) {
    $statusShapes = @($doc.SelectNodes('//p:sp', $manager) | Where-Object { (Get-ShapeText $_ $manager) -in @('已实现', '未完成') })
    if ($statusShapes.Count -ne 5) { throw "Expected five status badges, found $($statusShapes.Count)." }
    $changes = [ordered]@{
        '扩展要求与项目实现' = '用到的主要技术'
        '赛题要求至少实现 1 项扩展；项目现有工程已覆盖多项，转场特效不计入已完成项。' = '系统从基础多媒体、扩展图像处理到音游逻辑，主要采用以下技术。'
        '图层叠加 / 字幕' = 'TF 卡与 FAT32 文件系统'
        '已有 OSD、状态信息与音游 HUD RTL；仿真检查通过。' = '通过 SPI 读取 BMP、WAV 和谱面资源，支持簇链与缓存调度。'
        '图片切换 / 转场' = 'SDRAM 帧缓存与 HDMI'
        '未找到淡入淡出或滑动转场实现记录。' = '完成图像缓存、视频时序输出和 48 kHz HDMI 音频。'
        '不同分辨率图片缩放' = '双线性缩放与图像调节'
        '解析 BMP 尺寸并以双线性插值缩放到 640×480；回归通过。' = 'BMP 尺寸解析、双线性缩放及亮度、对比度和 OSD 控制。'
        '实时显示参数调节' = 'FFT 频谱与画面叠加'
        '亮度、对比度、锐度调节，并显示 OSD；保留 UART 控制。' = '对 PCM 音频进行频谱分析，输出环形频谱可视化画面。'
        '音频可视化' = '四轨音游引擎'
        '2048 点 FFT 与环形频谱显示；相关回归通过。' = 'OSZ 谱面转换、PCM 计时、Tap/Hold 判定与游戏 HUD 渲染。'
    }
    foreach ($old in $changes.Keys) { Set-ShapeText (Find-Shape $doc $old $manager) $changes[$old] $manager }
    $labels = @('基础', '基础', '扩展', '扩展', '音游')
    for ($i = 0; $i -lt $statusShapes.Count; $i++) { Set-ShapeText $statusShapes[$i] $labels[$i] $manager }
}

function Update-Slide4([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$manager) {
    $changes = [ordered]@{
        '基础系统' = '基础要求'
        '多媒体功能已有实现' = '图片、音频与切换播放'
        'BMP / FAT32 读取、SDRAM 帧缓存、手动切图与轮播、音频播放及显示参数控制。' = 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。'
        '扩展功能' = '扩展要求'
        '多项扩展有工程证据' = '图像处理与音频可视化'
        '双线性缩放、亮度/对比度/锐度调节、OSD 与环形 FFT 频谱。' = '双线性缩放、显示参数调节、OSD 与环形 FFT 频谱等功能已完成 RTL 与仿真。'
        '413 音符' = '音游'
        '真实谱面资源转换' = '谱面、音乐与游戏显示'
        '364 Tap + 49 Hold；配套 48 kHz PCM 音频约 90.07 秒。' = '413 个音符和 90.07 秒音乐资源完成转换，已接入四轨游戏界面。'
        '413 / 413' = '音游'
        '整曲判定逻辑仿真' = '整曲判定逻辑验证'
        'AUTO：413 Perfect、连击 413、100 万分；TEST：413 Miss。' = 'AUTO：413 Perfect、连击 413、100 万分；TEST：413 Miss。'
    }
    foreach ($old in $changes.Keys) { Set-ShapeText (Find-Shape $doc $old $manager) $changes[$old] $manager }
}

$readZip = [System.IO.Compression.ZipFile]::OpenRead($source)
try {
    $writeZip = [System.IO.Compression.ZipFile]::Open($destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $readZip.Entries) {
            $targetEntry = $writeZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $input = $entry.Open(); $output = $targetEntry.Open()
            try {
                if ($entry.FullName -in @('ppt/slides/slide2.xml', 'ppt/slides/slide3.xml', 'ppt/slides/slide4.xml')) {
                    $reader = [System.IO.StreamReader]::new($input, [System.Text.Encoding]::UTF8, $true)
                    try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $doc = [System.Xml.XmlDocument]::new(); $doc.PreserveWhitespace = $true; $doc.LoadXml($xml)
                    $manager = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
                    $manager.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
                    $manager.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
                    switch ($entry.FullName) {
                        'ppt/slides/slide2.xml' { Update-Slide2 $doc $manager }
                        'ppt/slides/slide3.xml' { Update-Slide3 $doc $manager }
                        'ppt/slides/slide4.xml' { Update-Slide4 $doc $manager }
                    }
                    $writer = [System.IO.StreamWriter]::new($output, [System.Text.UTF8Encoding]::new($false))
                    try { $doc.Save($writer) } finally { $writer.Dispose() }
                } else { $input.CopyTo($output) }
            } finally { $input.Dispose(); $output.Dispose() }
        }
    } finally { $writeZip.Dispose() }
} finally { $readZip.Dispose() }

[pscustomobject]@{ Output = $destination; Status = 'Slides 2 to 4 reorganized.' } | ConvertTo-Json

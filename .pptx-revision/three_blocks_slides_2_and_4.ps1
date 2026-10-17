Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_三部分版.pptx'
$destination = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_三板块.pptx'

if (-not (Test-Path -LiteralPath $source)) { throw "Source PPTX not found: $source" }
if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }

function Get-Text([System.Xml.XmlElement]$shape, [System.Xml.XmlNamespaceManager]$ns) {
    (($shape.SelectNodes('.//a:t', $ns) | ForEach-Object { $_.InnerText }) -join '')
}
function Set-Text([System.Xml.XmlElement]$shape, [string]$value, [System.Xml.XmlNamespaceManager]$ns) {
    $nodes = @($shape.SelectNodes('.//a:t', $ns))
    if ($nodes.Count -eq 0) { throw 'Target has no text run.' }
    $nodes[0].InnerText = $value
    foreach ($node in $nodes | Select-Object -Skip 1) { $node.InnerText = '' }
}
function Frame([System.Xml.XmlElement]$shape, [System.Xml.XmlNamespaceManager]$ns) {
    $off=$shape.SelectSingleNode('./p:spPr/a:xfrm/a:off',$ns); $ext=$shape.SelectSingleNode('./p:spPr/a:xfrm/a:ext',$ns)
    if ($null -eq $off -or $null -eq $ext) { throw 'Target has no frame.' }
    return "$($off.x),$($off.y),$($ext.cx),$($ext.cy)"
}
function Set-Frame([System.Xml.XmlElement]$shape, [int64]$x, [int64]$y, [int64]$w, [int64]$h, [System.Xml.XmlNamespaceManager]$ns) {
    $off=$shape.SelectSingleNode('./p:spPr/a:xfrm/a:off',$ns); $ext=$shape.SelectSingleNode('./p:spPr/a:xfrm/a:ext',$ns)
    $off.SetAttribute('x',[string]$x); $off.SetAttribute('y',[string]$y); $ext.SetAttribute('cx',[string]$w); $ext.SetAttribute('cy',[string]$h)
}
function Find-Text([System.Xml.XmlDocument]$doc, [string]$value, [System.Xml.XmlNamespaceManager]$ns) {
    $matches=@($doc.SelectNodes('//p:sp',$ns) | Where-Object {(Get-Text $_ $ns) -eq $value})
    if($matches.Count -ne 1){throw "Expected one shape with text [$value], found $($matches.Count)."}
    $matches[0]
}
function Find-Frame([System.Xml.XmlDocument]$doc, [string]$frame, [System.Xml.XmlNamespaceManager]$ns) {
    $matches=@($doc.SelectNodes('//p:sp',$ns) | Where-Object {(Frame $_ $ns) -eq $frame})
    if($matches.Count -ne 1){throw "Expected one shape at frame [$frame], found $($matches.Count)."}
    $matches[0]
}
function Delete-Shape([System.Xml.XmlElement]$shape) { [void]$shape.ParentNode.RemoveChild($shape) }
function New-ShapeId([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$ns) {
    $ids=@($doc.SelectNodes('//p:cNvPr',$ns) | ForEach-Object {[int]$_.id}); ([int](($ids | Measure-Object -Maximum).Maximum) + 1)
}
function Clone-Shape([System.Xml.XmlDocument]$doc, [System.Xml.XmlElement]$shape, [System.Xml.XmlNamespaceManager]$ns) {
    $clone=[System.Xml.XmlElement]$shape.CloneNode($true)
    $cNvPr=$clone.SelectSingleNode('.//p:cNvPr',$ns)
    $cNvPr.SetAttribute('id',[string](New-ShapeId $doc $ns))
    $tree=$doc.SelectSingleNode('//p:spTree',$ns); [void]$tree.AppendChild($clone); $clone
}

function Update-Slide2([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$ns) {
    # Remove the old bottom banner and its one-line audio-game text.
    Delete-Shape (Find-Frame $doc '609600,5257800,10972800,628650' $ns)
    Delete-Shape (Find-Text $doc '音游：加载 GAME.BIN 与 GAME.WAV，完成四轨 Tap / Hold 判定、计分结算和 HDMI 游戏 HUD。' $ns)

    $x1=609600; $x2=4400550; $x3=8191500; $y=1905000; $w=3390900; $h=3524250
    # Basic-requirements block.
    Set-Frame (Find-Frame $doc '609600,2000250,5353050,3028950' $ns) $x1 $y $w $h $ns
    Set-Frame (Find-Frame $doc '819150,2190750,1866900,266700' $ns) 800100 2095500 1143000 266700 $ns
    Set-Frame (Find-Text $doc '基础要求' $ns) 895350 2095500 952500 266700 $ns
    Set-Text (Find-Text $doc '基础多媒体播放' $ns) '图片、音频与切换' $ns
    Set-Frame (Find-Text $doc '图片、音频与切换' $ns) 800100 2667000 3009900 457200 $ns
    Set-Text (Find-Text $doc 'TF 卡 BMP 读取、SDRAM 帧缓存、HDMI 显示、手动切图与自动轮播。' $ns) 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns
    Set-Frame (Find-Text $doc 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns) 800100 3333750 3009900 1524000 $ns
    Delete-Shape (Find-Text $doc 'HDMI 音频输出' $ns)
    Delete-Shape (Find-Text $doc '输出 48 kHz PCM 音频，与图片显示共同构成音视频播放系统。' $ns)

    # Extension-requirements block.
    Set-Frame (Find-Frame $doc '6229350,2000250,5353050,3028950' $ns) $x2 $y $w $h $ns
    Set-Frame (Find-Frame $doc '6438900,2190750,1295400,266700' $ns) 4591050 2095500 1143000 266700 $ns
    Set-Frame (Find-Text $doc '扩展要求' $ns) 4686300 2095500 952500 266700 $ns
    Set-Text (Find-Text $doc '图像处理与音频可视化' $ns) '图像处理与可视化' $ns
    Set-Frame (Find-Text $doc '图像处理与可视化' $ns) 4591050 2667000 3009900 457200 $ns
    $extensionBullets=@(
        @('双线性缩放适配不同分辨率 BMP。',3295650),
        @('亮度、对比度调节与 OSD 参数显示。',3905250),
        @('FFT 频谱与视频画面叠加显示。',4514850)
    )
    $oldBullets=@('双线性缩放适配不同分辨率 BMP。','亮度、对比度调节与 OSD 参数显示。','FFT 频谱与视频画面叠加显示。')
    for($i=0;$i -lt 3;$i++){
        $dot=Find-Frame $doc @('6457950,3390900,76200,76200','6457950,3981450,76200,76200','6457950,4572000,76200,76200')[$i] $ns
        Set-Frame $dot 4591050 $($extensionBullets[$i][1] + 95250) 76200 76200 $ns
        $txt=Find-Text $doc $oldBullets[$i] $ns
        Set-Frame $txt 4800600 $extensionBullets[$i][1] 2790825 457200 $ns
    }

    # Clone the compact basic block into a third audio-game block.
    $panel=Clone-Shape $doc (Find-Frame $doc "$x1,$y,$w,$h" $ns) $ns; Set-Frame $panel $x3 $y $w $h $ns
    $badgeBox=Clone-Shape $doc (Find-Frame $doc '800100,2095500,1143000,266700' $ns) $ns; Set-Frame $badgeBox 8382000 2095500 1143000 266700 $ns
    $badge=Clone-Shape $doc (Find-Text $doc '基础要求' $ns) $ns; Set-Text $badge '音游' $ns; Set-Frame $badge 8477250 2095500 952500 266700 $ns
    $title=Clone-Shape $doc (Find-Text $doc '图片、音频与切换' $ns) $ns; Set-Text $title '谱面、判定与游戏 HUD' $ns; Set-Frame $title 8382000 2667000 3009900 457200 $ns
    $body=Clone-Shape $doc (Find-Text $doc 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns) $ns
    Set-Text $body 'OSZ 谱面转换、GAME.BIN/GAME.WAV 读取、Tap/Hold 判定、计分结算与 HDMI 游戏界面。' $ns
    Set-Frame $body 8382000 3333750 3009900 1524000 $ns
}

function Update-Slide3([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$ns) {
    Delete-Shape (Find-Frame $doc '609600,5810250,10972800,342900' $ns)
}

function Update-Slide4([System.Xml.XmlDocument]$doc, [System.Xml.XmlNamespaceManager]$ns) {
    # Delete the bottom banner and the fourth card. The audio-game block occupies the third card.
    Delete-Shape (Find-Frame $doc '609600,5429250,10972800,552450' $ns)
    Delete-Shape (Find-Frame $doc '6172200,3352800,5219700,1524000' $ns)
    Delete-Shape (Find-Frame $doc '6172200,3352800,76200,1524000' $ns)
    $audioLabel4=@($doc.SelectNodes('//p:sp',$ns) | Where-Object {(Get-Text $_ $ns) -eq '音游' -and (Frame $_ $ns) -eq '6438900,3543300,2000250,514350'})
    if($audioLabel4.Count -ne 1){throw 'Fourth-card audio label not found.'}; Delete-Shape $audioLabel4[0]
    Delete-Shape (Find-Text $doc '整曲判定逻辑验证' $ns)
    Delete-Shape (Find-Text $doc 'AUTO：413 Perfect、连击 413、100 万分；TEST：413 Miss。' $ns)

    $x1=609600; $x2=4400550; $x3=8191500; $y=1666875; $w=3390900; $h=3476625
    # First card: basic requirements.
    Set-Frame (Find-Frame $doc '609600,1504950,5219700,1524000' $ns) $x1 $y $w $h $ns
    Set-Frame (Find-Frame $doc '609600,1504950,76200,1524000' $ns) $x1 $y 76200 $h $ns
    Set-Frame (Find-Text $doc '基础要求' $ns) 876300 1857375 2381250 514350 $ns
    Set-Frame (Find-Text $doc '图片、音频与切换播放' $ns) 876300 2428875 2857500 457200 $ns
    Set-Text (Find-Text $doc 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns) 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns
    Set-Frame (Find-Text $doc 'BMP/FAT32 读取、SDRAM 帧缓存、HDMI 显示、手动切图/自动轮播和 48 kHz 音频。' $ns) 876300 3190875 2857500 1333500 $ns

    # Second card: extension requirements.
    Set-Frame (Find-Frame $doc '6172200,1504950,5219700,1524000' $ns) $x2 $y $w $h $ns
    Set-Frame (Find-Frame $doc '6172200,1504950,76200,1524000' $ns) $x2 $y 76200 $h $ns
    Set-Frame (Find-Text $doc '扩展要求' $ns) 4667250 1857375 2381250 514350 $ns
    Set-Frame (Find-Text $doc '图像处理与音频可视化' $ns) 4667250 2428875 2857500 457200 $ns
    Set-Text (Find-Text $doc '双线性缩放、显示参数调节、OSD 与环形 FFT 频谱等功能已完成 RTL 与仿真。' $ns) '双线性缩放、显示参数调节、OSD 与环形 FFT 频谱等扩展功能已完成 RTL 与仿真。' $ns
    Set-Frame (Find-Text $doc '双线性缩放、显示参数调节、OSD 与环形 FFT 频谱等扩展功能已完成 RTL 与仿真。' $ns) 4667250 3190875 2857500 1333500 $ns

    # Third card: rhythm game.
    Set-Frame (Find-Frame $doc '609600,3352800,5219700,1524000' $ns) $x3 $y $w $h $ns
    Set-Frame (Find-Frame $doc '609600,3352800,76200,1524000' $ns) $x3 $y 76200 $h $ns
    Set-Frame (Find-Text $doc '音游' $ns) 8458200 1857375 2381250 514350 $ns
    Set-Text (Find-Text $doc '谱面、音乐与游戏显示' $ns) '谱面、判定与游戏 HUD' $ns
    Set-Frame (Find-Text $doc '谱面、判定与游戏 HUD' $ns) 8458200 2428875 2857500 457200 $ns
    Set-Text (Find-Text $doc '413 个音符和 90.07 秒音乐资源完成转换，已接入四轨游戏界面。' $ns) '413 个音符与 90.07 秒音乐完成转换；整曲 AUTO 413 Perfect、连击 413、100 万分。' $ns
    Set-Frame (Find-Text $doc '413 个音符与 90.07 秒音乐完成转换；整曲 AUTO 413 Perfect、连击 413、100 万分。' $ns) 8458200 3190875 2857500 1333500 $ns
}

$readZip=[System.IO.Compression.ZipFile]::OpenRead($source)
try {
    $writeZip=[System.IO.Compression.ZipFile]::Open($destination,[System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($entry in $readZip.Entries){
            $outEntry=$writeZip.CreateEntry($entry.FullName,[System.IO.Compression.CompressionLevel]::Optimal)
            $input=$entry.Open(); $output=$outEntry.Open()
            try {
                if($entry.FullName -in @('ppt/slides/slide2.xml','ppt/slides/slide3.xml','ppt/slides/slide4.xml')){
                    $reader=[System.IO.StreamReader]::new($input,[System.Text.Encoding]::UTF8,$true); try{$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
                    $doc=[System.Xml.XmlDocument]::new();$doc.PreserveWhitespace=$true;$doc.LoadXml($xml)
                    $ns=[System.Xml.XmlNamespaceManager]::new($doc.NameTable);$ns.AddNamespace('p','http://schemas.openxmlformats.org/presentationml/2006/main');$ns.AddNamespace('a','http://schemas.openxmlformats.org/drawingml/2006/main')
                    switch($entry.FullName){'ppt/slides/slide2.xml'{Update-Slide2 $doc $ns}'ppt/slides/slide3.xml'{Update-Slide3 $doc $ns}'ppt/slides/slide4.xml'{Update-Slide4 $doc $ns}}
                    $writer=[System.IO.StreamWriter]::new($output,[System.Text.UTF8Encoding]::new($false));try{$doc.Save($writer)}finally{$writer.Dispose()}
                } else {$input.CopyTo($output)}
            } finally {$input.Dispose();$output.Dispose()}
        }
    } finally {$writeZip.Dispose()}
} finally {$readZip.Dispose()}

[pscustomobject]@{Output=$destination;Status='Slides 2 and 4 use three blocks; all three bottom banners removed.'}|ConvertTo-Json

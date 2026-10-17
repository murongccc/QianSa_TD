Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_三板块.pptx'
$destination = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_音游表述调整.pptx'
if (-not (Test-Path -LiteralPath $source)) { throw "Source PPTX not found: $source" }
if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }

$readZip = [System.IO.Compression.ZipFile]::OpenRead($source)
try {
    $writeZip = [System.IO.Compression.ZipFile]::Open($destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $readZip.Entries) {
            $outEntry = $writeZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $input = $entry.Open(); $output = $outEntry.Open()
            try {
                if ($entry.FullName -eq 'ppt/slides/slide4.xml') {
                    $reader = [System.IO.StreamReader]::new($input, [System.Text.Encoding]::UTF8, $true)
                    try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $doc = [System.Xml.XmlDocument]::new(); $doc.PreserveWhitespace = $true; $doc.LoadXml($xml)
                    $ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
                    $ns.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
                    $ns.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')

                    $heading = @($doc.SelectNodes('//p:sp', $ns) | Where-Object { (($_.SelectNodes('.//a:t', $ns) | ForEach-Object { $_.InnerText }) -join '') -eq '谱面、判定与游戏 HUD' })
                    if ($heading.Count -ne 1) { throw "Expected one rhythm-game heading, found $($heading.Count)." }
                    $heading.SelectSingleNode('.//a:t', $ns).InnerText = '音游功能集成与验证'

                    $bodyText = '413 个音符与 90.07 秒音乐完成转换；整曲 AUTO 413 Perfect、连击 413、100 万分。'
                    $body = @($doc.SelectNodes('//p:sp', $ns) | Where-Object { (($_.SelectNodes('.//a:t', $ns) | ForEach-Object { $_.InnerText }) -join '') -eq $bodyText })
                    if ($body.Count -ne 1) { throw "Expected one rhythm-game result text, found $($body.Count)." }
                    $runs = @($body[0].SelectNodes('.//a:t', $ns))
                    $runs[0].InnerText = '已完成音游核心功能开发与阶段性验证，涵盖音乐播放、谱面处理、游戏判定和画面显示。'
                    foreach ($run in $runs | Select-Object -Skip 1) { $run.InnerText = '' }

                    $writer = [System.IO.StreamWriter]::new($output, [System.Text.UTF8Encoding]::new($false))
                    try { $doc.Save($writer) } finally { $writer.Dispose() }
                } else { $input.CopyTo($output) }
            } finally { $input.Dispose(); $output.Dispose() }
        }
    } finally { $writeZip.Dispose() }
} finally { $readZip.Dispose() }

[pscustomobject]@{ Output = $destination; Status = 'Slide 4 rhythm-game result wording broadened.' } | ConvertTo-Json

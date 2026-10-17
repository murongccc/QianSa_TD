Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版.pptx'
$destination = 'E:\AnLuTD_Project\SD_to_Video\presentation\FPGA音画联动音游_赛题对照版_修订.pptx'
$targets = @(
    '说明：以上“已实现”指工程 RTL / 仿真阶段；各扩展效果仍须并入最终固化版本并完成板级验收。',
    '当前差距：时序仍未闭合，未生成最终 bitstream；音游、基础功能与扩展功能的整机板级验收尚未完成。',
    '最终验收约束：指定 HX4S20C；基础项与扩展项须整合为单份固化设计，上电即可运行。当前尚未生成 bitstream，整机上板验收待完成。'
)

if (-not (Test-Path -LiteralPath $source)) { throw "Source PPTX not found: $source" }
if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }

$readZip = [System.IO.Compression.ZipFile]::OpenRead($source)
try {
    $writeZip = [System.IO.Compression.ZipFile]::Open($destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $removed = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $readZip.Entries) {
            $outputEntry = $writeZip.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
            $inputStream = $entry.Open()
            $outputStream = $outputEntry.Open()
            try {
                if ($entry.FullName -like 'ppt/slides/slide*.xml') {
                    $reader = [System.IO.StreamReader]::new($inputStream, [System.Text.Encoding]::UTF8, $true)
                    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $doc = [System.Xml.XmlDocument]::new()
                    $doc.PreserveWhitespace = $true
                    $doc.LoadXml($xmlText)
                    $manager = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
                    $manager.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
                    $manager.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
                    foreach ($shape in @($doc.SelectNodes('//p:sp', $manager))) {
                        $shapeText = (($shape.SelectNodes('.//a:t', $manager) | ForEach-Object { $_.InnerText }) -join '')
                        if ($targets -contains $shapeText) {
                            [void]$shape.ParentNode.RemoveChild($shape)
                            $removed.Add($shapeText)
                        }
                    }
                    $writer = [System.IO.StreamWriter]::new($outputStream, [System.Text.UTF8Encoding]::new($false))
                    try { $doc.Save($writer) } finally { $writer.Dispose() }
                } else {
                    $inputStream.CopyTo($outputStream)
                }
            } finally {
                $inputStream.Dispose()
                $outputStream.Dispose()
            }
        }
        if ($removed.Count -ne 3) { throw "Expected to remove 3 text boxes, removed $($removed.Count)." }
        [pscustomobject]@{ Output = $destination; Removed = $removed } | ConvertTo-Json -Depth 3
    } finally {
        $writeZip.Dispose()
    }
} finally {
    $readZip.Dispose()
}

param([string]$IsoPath='', [string]$OutputIso='', [string]$DeltaPath=(Join-Path $PSScriptRoot 'preflight-parallel-queue.delta.json'), [switch]$NoOpen)
$ErrorActionPreference='Stop'
function Read-At([IO.BinaryReader]$Reader,[long]$Offset,[int]$Count) {
    if($Offset -lt 0 -or $Count -lt 0 -or $Offset -gt $Reader.BaseStream.Length-$Count){throw 'A disc structure is outside the input file.'}
    $Reader.BaseStream.Position=$Offset;$bytes=$Reader.ReadBytes($Count)
    if($bytes.Length -ne $Count){throw 'The input file ended unexpectedly.'}
    return ,$bytes
}
function Big32([byte[]]$Bytes,[int]$Offset) {
    if($Offset -lt 0 -or $Offset+4 -gt $Bytes.Length){throw 'Invalid field offset.'}
    return [uint64]$Bytes[$Offset]*16777216+[uint64]$Bytes[$Offset+1]*65536+[uint64]$Bytes[$Offset+2]*256+[uint64]$Bytes[$Offset+3]
}
function BE32([uint32]$Value) {return ,[byte[]]@(($Value -shr 24), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255))}
function Hash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Apply-Recipe([byte[]]$Original,$Patch) {
    if($Original.Length -ne $Patch.OriginalBytes -or (Hash $Original) -cne $Patch.OriginalSHA256){throw 'This is not the supported Preflight v1.1 module. No output was written.'}
    if($Patch.OutputBytes -le 0 -or $Patch.OutputBytes -gt 4194304){throw 'Invalid output size.'}
    $buffer=New-Object IO.MemoryStream
    try {
        foreach($operation in $Patch.Operations) {
            if($null -ne $operation.Copy) {
                [long]$start=$operation.Copy;[long]$length=$operation.Length
                if($start -lt 0 -or $length -lt 0 -or $start -gt $Original.Length-$length){throw 'Invalid patch copy range.'}
                $buffer.Write($Original,[int]$start,[int]$length)
            } else {
                $data=[Convert]::FromBase64String($operation.Data);$buffer.Write($data,0,$data.Length)
            }
            if($buffer.Length -gt $Patch.OutputBytes){throw 'Patch exceeds declared output size.'}
        }
        $result=$buffer.ToArray()
        if($result.Length -ne $Patch.OutputBytes -or (Hash $result) -cne $Patch.OutputSHA256){throw 'Patched module failed verification.'}
        return ,$result
    } finally {$buffer.Dispose()}
}
$temporary=''
try {
    $patch=Get-Content -Raw -LiteralPath $DeltaPath | ConvertFrom-Json
    if($patch.Format -cne 'Preflight parallel queue experimental patch 1'){throw 'Unsupported patch format.'}
    if([string]::IsNullOrWhiteSpace($IsoPath)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title='Choose your original, working Preflight v1.1 ISO'
        $dialog.Filter='Uncompressed GameCube disc|*.iso;*.gcm'
        try {if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){exit 0};$IsoPath=$dialog.FileName}finally{$dialog.Dispose()}
    }
    $IsoPath=[IO.Path]::GetFullPath($IsoPath)
    $reader=New-Object IO.BinaryReader([IO.File]::Open($IsoPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $files=@{};$allFiles=New-Object 'Collections.Generic.List[object]';$prepared=@{}
    try {
        $header=Read-At $reader 0 1088
        if([Text.Encoding]::ASCII.GetString($header,0,6) -cne 'GALE01' -or $header[7] -ne 2 -or (Big32 $header 28) -ne 3258163005){throw 'Choose the original supported Preflight ISO (GALE01 revision 2).'}
        $dolOffset=Big32 $header 1056;$fstOffset=Big32 $header 1060;$fstSize=Big32 $header 1064
        if($dolOffset -lt 1088 -or $fstOffset -lt 1088 -or $fstSize -lt 12 -or $fstSize -gt 16777216){throw 'Invalid disc header.'}
        $dh=Read-At $reader $dolOffset 256;[long]$dolSize=256
        for($i=0;$i -lt 18;$i++) {
            $offset=Big32 $dh ($i*4);$size=Big32 $dh (144+$i*4)
            if($size -eq 0){continue}
            if($offset -lt 256 -or $offset+$size -gt 33554432){throw 'Invalid executable section.'}
            $dolSize=[Math]::Max($dolSize,$offset+$size)
        }
        if((Hash (Read-At $reader $dolOffset $dolSize)) -cne $patch.DolSHA256){throw 'The executable does not match this Preflight patch.'}
        $fst=Read-At $reader $fstOffset $fstSize;$count=Big32 $fst 8
        if($fst[0] -ne 1 -or $count -lt 1 -or $count -gt 50000 -or $count*12 -gt $fst.Length){throw 'Invalid filesystem table.'}
        $directories=New-Object 'Collections.Generic.List[object]';$directories.Add([pscustomobject]@{Path='';End=$count})
        for($i=1;$i -lt $count;$i++) {
            while($directories.Count -gt 1 -and $i -ge $directories[$directories.Count-1].End){$directories.RemoveAt($directories.Count-1)}
            $word=Big32 $fst ($i*12);$start=[int]($count*12+($word -band 16777215))
            if($start -lt $count*12 -or $start -ge $fst.Length){throw 'Invalid filesystem name.'}
            $end=$start;while($end -lt $fst.Length -and $fst[$end] -ne 0 -and $end-$start -le 4096){$end++}
            if($end -ge $fst.Length -or $end-$start -gt 4096){throw 'Invalid filesystem name length.'}
            $name=[Text.Encoding]::UTF8.GetString($fst,$start,$end-$start);$path=$directories[$directories.Count-1].Path+$name
            $offset=Big32 $fst ($i*12+4);$size=Big32 $fst ($i*12+8)
            if(($word -shr 24) -eq 1) {
                if($size -le $i -or $size -gt $directories[$directories.Count-1].End){throw 'Invalid directory subtree.'}
                $directories.Add([pscustomobject]@{Path=($path+'/');End=$size})
            } elseif(($word -shr 24) -eq 0) {
                if($offset+$size -gt $reader.BaseStream.Length){throw 'A disc file is outside the input.'}
                $record=[pscustomobject]@{Path=$path;Offset=[long]$offset;Size=[int]$size;SizeField=([long]$fstOffset+$i*12+8)}
                $allFiles.Add($record)
                if($path -ceq 'tm.dat' -or $path -ceq 'other.dat' -or $path -ceq 'codes.gct') {
                    if($files.ContainsKey($path)){throw 'Duplicate module.'}
                    if($size -le 0 -or $size -gt 4194304){throw 'Invalid module size.'}
                    $files[$path]=$record
                }
            } else {throw 'Invalid filesystem entry type.'}
        }
        foreach($name in @('tm.dat','other.dat','codes.gct')){if(-not $files.ContainsKey($name)){throw "Missing $name."}}
        $record=$files['codes.gct']
        if((Hash (Read-At $reader $record.Offset $record.Size)) -cne $patch.CodesSHA256){throw 'The loader codes do not match this patch.'}
        foreach($name in @('tm.dat','other.dat')) {
            $record=$files[$name]
            $prepared[$name]=Apply-Recipe (Read-At $reader $record.Offset $record.Size) $patch.Files.$name
            [long]$limit=$reader.BaseStream.Length
            foreach($other in $allFiles) {
                if($other.Path -ceq $name -or $other.Size -eq 0){continue}
                if($other.Offset -lt $record.Offset+$record.Size -and $other.Offset+$other.Size -gt $record.Offset){throw 'Overlapping disc files.'}
                if($other.Offset -ge $record.Offset){$limit=[Math]::Min($limit,$other.Offset)}
            }
            foreach($region in @(@($dolOffset,$dolSize),@($fstOffset,$fstSize))) {
                if($region[0] -lt $record.Offset+$record.Size -and $region[0]+$region[1] -gt $record.Offset){throw 'Module overlaps executable or filesystem table.'}
                if($region[0] -ge $record.Offset){$limit=[Math]::Min($limit,$region[0])}
            }
            if($record.Offset+$prepared[$name].Length -gt $limit){throw "Not enough padding after $name. This disc layout is unsupported."}
        }
    } finally {$reader.Dispose()}
    if([string]::IsNullOrWhiteSpace($OutputIso)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title='Save a NEW experimental Preflight ISO';$dialog.Filter='GameCube ISO|*.iso'
        $dialog.FileName='Preflight-ParallelQueue-test.iso';$dialog.OverwritePrompt=$true
        try {if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){exit 0};$OutputIso=$dialog.FileName}finally{$dialog.Dispose()}
    }
    $OutputIso=[IO.Path]::GetFullPath($OutputIso)
    if(Test-Path -LiteralPath $OutputIso){throw 'Choose a new filename. Existing files are preserved.'}
    $temporary=$OutputIso+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    [IO.File]::Copy($IsoPath,$temporary,$false)
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        foreach($name in @('tm.dat','other.dat')) {
            $record=$files[$name];[byte[]]$bytes=$prepared[$name]
            $stream.Position=$record.Offset;$stream.Write($bytes,0,$bytes.Length)
            $sizeBytes=BE32 $bytes.Length;$stream.Position=$record.SizeField;$stream.Write($sizeBytes,0,4)
        }
        $stream.Flush()
        foreach($name in @('tm.dat','other.dat')) {
            $record=$files[$name];$stream.Position=$record.Offset;$bytes=New-Object byte[] $prepared[$name].Length
            if($stream.Read($bytes,0,$bytes.Length) -ne $bytes.Length -or (Hash $bytes) -cne $patch.Files.$name.OutputSHA256){throw 'Output verification failed.'}
        }
    } finally {$stream.Dispose()}
    [IO.File]::Move($temporary,$OutputIso);$temporary=''
    Write-Host "Saved and verified: $OutputIso" -ForegroundColor Green
    Write-Host 'Use this ISO with the matching experimental single-instance Dolphin build.'
    if(-not $NoOpen){Start-Process explorer.exe -ArgumentList ('/select,"'+$OutputIso+'"')}
} catch {
    Write-Error $_
    exit 1
} finally {
    if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
}

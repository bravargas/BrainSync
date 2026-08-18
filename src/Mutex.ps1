# ------------------------------------------------------------
# BrainSync - Concurrency / Mutex Module
# ------------------------------------------------------------

$Script:Mutex = $null
$Script:MutexAcquired = $false

function Acquire-BrainSyncMutex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $MutexName = "Global\BrainSync_$ComputerName"

    try {
        $Script:Mutex = [System.Threading.Mutex]::new(
            $false,
            $MutexName
        )

        try {
            $Script:MutexAcquired = $Script:Mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Previous BrainSync process terminated unexpectedly.
            # Windows grants this execution ownership of the mutex.
            $Script:MutexAcquired = $true
        }

        if (-not $Script:MutexAcquired) {
            if ($Script:Mutex) {
                $Script:Mutex.Dispose()
                $Script:Mutex = $null
            }
            return $false
        }

        return $true
    }
    catch {
        if ($Script:Mutex) {
            $Script:Mutex.Dispose()
            $Script:Mutex = $null
        }

        throw "Failed to create BrainSync mutex: $($_.Exception.Message)"
    }
}

function Release-BrainSyncMutex {
    if ($Script:MutexAcquired -and $Script:Mutex) {
        try {
            $Script:Mutex.ReleaseMutex()
        }
        catch {
            # Nothing else to do here.
        }

        $Script:MutexAcquired = $false
    }

    if ($Script:Mutex) {
        $Script:Mutex.Dispose()
        $Script:Mutex = $null
    }
}

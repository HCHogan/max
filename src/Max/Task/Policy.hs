module Max.Task.Policy (frontendToolLimit, frontendDeadlineSeconds, frontendLeaseSeconds) where

frontendToolLimit :: Int
frontendToolLimit = 600

frontendDeadlineSeconds :: Int
frontendDeadlineSeconds = 3600

-- Leave time for the terminal checkpoint after the foreground deadline.
frontendLeaseSeconds :: Int
frontendLeaseSeconds = frontendDeadlineSeconds + 150

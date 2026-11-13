local time = {};

-- Get current time in seconds
function time.now()
    return os.clock();
end

-- Check if time has elapsed
function time.has_elapsed(start_time, duration)
    return (time.now() - start_time) >= duration;
end

return time;
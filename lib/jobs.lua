-- HiveMind job queue
--
-- A breeding campaign runs for hours of game time across eight machines. The
-- computer will be stopped, the chunk will unload, the power will dip. So the
-- queue is built around one rule:
--
--   A step never trusts what was written down. It looks at the world first.
--
-- Every step declares a `verify` that answers "is this already done?" against
-- the actual machines, and a `run` that performs it. On resume the recorded step
-- number only says where to look; `verify` decides whether to skip. That is what
-- makes a crash between "the Mutatron produced a queen" and "I wrote that down"
-- harmless: the queen is visible, so the step is skipped.
--
-- The queue is persisted after every state change, never in the middle of one.

local state = require("lib.state")

local jobs = {}

-- What a step's run() may answer
jobs.DONE = "done"       -- step achieved, move to the next one
jobs.RETRY = "retry"     -- nothing wrong, just not now (no energy, machine busy)
jobs.FAILED = "failed"   -- this job cannot proceed

-- Job lifecycle
jobs.PENDING = "pending"
jobs.RUNNING = "running"
jobs.COMPLETE = "complete"
jobs.ERROR = "error"
jobs.CANCELLED = "cancelled"

jobs.DEFAULT_MAX_ATTEMPTS = 3

local Queue = {}
Queue.__index = Queue

--- Create a job queue
--- @param options table|nil {path, handlers, maxAttempts, clock}
---   handlers  map of job type -> {steps = {{name, verify, run}, ...}}
---   clock     function returning a timestamp, injectable for tests
--- @return table queue
function jobs.new(options)
    options = options or {}

    return setmetatable({
        path = options.path or state.pathFor("jobs"),
        handlers = options.handlers or {},
        maxAttempts = options.maxAttempts or jobs.DEFAULT_MAX_ATTEMPTS,
        clock = options.clock or os.time,
        data = {nextId = 1, queue = {}},
        loaded = false,
    }, Queue)
end

--- Read the queue back from disk, once
--- @return boolean ok
--- @return string|nil error
function Queue:load()
    if self.loaded then return true end
    self.loaded = true

    local stored, err = state.load(self.path, nil)

    if err then
        -- Losing the queue is bad, but refusing to boot because of it is worse:
        -- report and start clean so the operator can decide.
        return false, "file de taches illisible, elle repart vide: " .. err
    end

    if stored and type(stored.queue) == "table" then
        self.data = stored
        self.data.nextId = stored.nextId or 1
    end

    return true
end

--- Persist the queue
--- @return boolean ok
--- @return string|nil error
function Queue:save()
    return state.save(self.path, self.data)
end

--- Queue a new job
--- @param kind string Job type, must have a registered handler
--- @param params table|nil Parameters carried through every step
--- @return number|nil id
--- @return string|nil error
function Queue:submit(kind, params)
    self:load()

    if type(kind) ~= "string" then return nil, "type de tache invalide" end
    if not self.handlers[kind] then return nil, "aucun gestionnaire pour: " .. kind end

    local id = self.data.nextId
    self.data.nextId = id + 1

    table.insert(self.data.queue, {
        id = id,
        kind = kind,
        params = params or {},
        step = 1,
        status = jobs.PENDING,
        attempts = 0,
        created = self.clock(),
        updated = self.clock(),
    })

    local ok, err = self:save()
    if not ok then return nil, err end

    return id
end

--- Fetch a job by id
--- @param id number
--- @return table|nil job
function Queue:get(id)
    self:load()

    for _, job in ipairs(self.data.queue) do
        if job.id == id then return job end
    end

    return nil
end

--- Every job, in submission order
--- @param status string|nil Filter on a status
--- @return table[] jobs
function Queue:list(status)
    self:load()

    if not status then return self.data.queue end

    local filtered = {}
    for _, job in ipairs(self.data.queue) do
        if job.status == status then table.insert(filtered, job) end
    end

    return filtered
end

--- Jobs still waiting to advance
--- A job left in RUNNING by a crash counts as pending again: that is exactly the
--- resume case, and its steps re-verify before acting.
--- @return table[] jobs
function Queue:pending()
    self:load()

    local waiting = {}
    for _, job in ipairs(self.data.queue) do
        if job.status == jobs.PENDING or job.status == jobs.RUNNING then
            table.insert(waiting, job)
        end
    end

    return waiting
end

--- Stop a job without running it further
--- @param id number
--- @return boolean ok
--- @return string|nil error
function Queue:cancel(id)
    local job = self:get(id)
    if not job then return false, "tache introuvable" end

    if job.status == jobs.COMPLETE then
        return false, "tache deja terminee"
    end

    job.status = jobs.CANCELLED
    job.updated = self.clock()

    return self:save()
end

--- Drop finished jobs from the queue
--- @return number removed
function Queue:prune()
    self:load()

    local kept = {}
    local removed = 0

    for _, job in ipairs(self.data.queue) do
        if job.status == jobs.COMPLETE or job.status == jobs.CANCELLED then
            removed = removed + 1
        else
            table.insert(kept, job)
        end
    end

    if removed > 0 then
        self.data.queue = kept
        self:save()
    end

    return removed
end

--- Advance one job by a single step
--- @param job table
--- @param context table Passed through to verify/run: machines, transport, ui
--- @return string outcome One of jobs.DONE, jobs.RETRY, jobs.FAILED
--- @return string|nil detail
function Queue:step(job, context)
    self:load()

    local handler = self.handlers[job.kind]
    if not handler or type(handler.steps) ~= "table" then
        job.status = jobs.ERROR
        job.error = "aucun gestionnaire pour: " .. tostring(job.kind)
        job.updated = self.clock()
        self:save()
        return jobs.FAILED, job.error
    end

    -- Past the last step means the job is done
    if job.step > #handler.steps then
        job.status = jobs.COMPLETE
        job.updated = self.clock()
        self:save()
        return jobs.DONE, "tache terminee"
    end

    local step = handler.steps[job.step]
    job.status = jobs.RUNNING
    job.updated = self.clock()
    -- Written down BEFORE acting, so a crash during the step is seen on resume
    self:save()

    -- Ask the world whether this was already achieved. This is what makes a
    -- crash between acting and recording harmless.
    if type(step.verify) == "function" then
        local ok, achieved = pcall(step.verify, job, context)
        if ok and achieved then
            job.step = job.step + 1
            job.attempts = 0
            job.error = nil
            -- Leaving RUNNING here made a merely waiting job look busy in every
            -- report, and only pending() accepting both statuses kept the queue
            -- from stalling on it.
            job.status = (job.step > #handler.steps) and jobs.COMPLETE or jobs.PENDING
            job.updated = self.clock()
            self:save()
            return jobs.DONE, "etape deja accomplie: " .. tostring(step.name)
        end
    end

    if type(step.run) ~= "function" then
        job.status = jobs.ERROR
        job.error = "etape sans action: " .. tostring(step.name)
        self:save()
        return jobs.FAILED, job.error
    end

    local ok, outcome, detail = pcall(step.run, job, context)

    if not ok then
        -- An error thrown inside a step is a failure, not a crash of the queue
        outcome, detail = jobs.FAILED, tostring(outcome)
    end

    if outcome == jobs.RETRY then
        job.status = jobs.PENDING
        job.error = detail
        job.updated = self.clock()
        self:save()
        return jobs.RETRY, detail
    end

    if outcome == jobs.DONE or outcome == true then
        job.step = job.step + 1
        job.attempts = 0
        job.error = nil
        job.status = (job.step > #handler.steps) and jobs.COMPLETE or jobs.PENDING
        job.updated = self.clock()
        self:save()
        return jobs.DONE, detail
    end

    -- Anything else is a failure; give it a few tries before giving up
    job.attempts = (job.attempts or 0) + 1
    job.error = detail or "echec sans raison"
    job.updated = self.clock()

    if job.attempts >= self.maxAttempts then
        job.status = jobs.ERROR
    else
        job.status = jobs.PENDING
    end

    self:save()
    return jobs.FAILED, job.error
end

--- Advance the queue until nothing can move
--- Stops on the first job that fails permanently, so the operator sees it rather
--- than having it buried under later work.
--- @param context table Passed to every step
--- @param options table|nil {maxSteps, onProgress}
--- @return table report {steps, completed, retried, failed, blocked}
function Queue:run(context, options)
    options = options or {}
    self:load()

    local report = {steps = 0, completed = 0, retried = 0, failed = 0, blocked = false}
    local limit = options.maxSteps or 1000

    while report.steps < limit do
        local job = self:pending()[1]
        if not job then break end

        local before_step = job.step
        local outcome, detail = self:step(job, context)
        report.steps = report.steps + 1

        if type(options.onProgress) == "function" then
            pcall(options.onProgress, job, outcome, detail)
        end

        if outcome == jobs.DONE then
            if job.status == jobs.COMPLETE then report.completed = report.completed + 1 end
        elseif outcome == jobs.RETRY then
            report.retried = report.retried + 1
            -- A job asking to wait must not be retried immediately in the same
            -- pass, or the loop spins on it. Stop and let the caller come back.
            report.blocked = true
            break
        else
            report.failed = report.failed + 1
            if job.status == jobs.ERROR then break end
            -- Not permanently failed: it will be retried on the next pass
            report.blocked = true
            break
        end

        -- Safety net against a verify/run pair that never advances
        if job.step == before_step and job.status ~= jobs.COMPLETE then
            report.blocked = true
            break
        end
    end

    return report
end

--- One-line summary per job, for the GUI and the logs
--- @return string[] lines
function Queue:describe()
    self:load()

    local lines = {}
    for _, job in ipairs(self.data.queue) do
        local handler = self.handlers[job.kind]
        local total = handler and handler.steps and #handler.steps or "?"
        table.insert(lines, string.format("#%d %-22s %-9s etape %s/%s%s",
            job.id, job.kind, job.status, tostring(job.step), tostring(total),
            job.error and ("  (" .. job.error .. ")") or ""))
    end

    return lines
end

return jobs

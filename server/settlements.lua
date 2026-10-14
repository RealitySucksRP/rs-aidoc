RSAIDocSettlements = {}

local key = 'rs_aidoc_settlements_v1'
local records = {}
local raw = GetResourceKvpString(key)
if raw and raw ~= '' then
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        error('RS AI Doc settlement journal is unreadable; refusing to overwrite it.')
    end
    records = decoded
end

local function save(id, entry)
    local previous = records[id]
    records[id] = entry
    local ok, encoded = pcall(json.encode, records)
    if ok then
        ok = pcall(function()
            SetResourceKvp(key, encoded)
            assert(GetResourceKvpString(key) == encoded, 'journal readback failed')
        end)
    end
    if not ok then
        records[id] = previous
        print(('[rs-aidoc] JOURNAL WRITE FAILED id=%s identity=%s'):format(id, entry.identity))
    end
    return ok
end

function RSAIDocSettlements.Record(session, state, reason)
    if session.price <= 0 then return true end
    return save(session.token, {
        identity = session.identity, account = session.account, amount = session.price,
        created = session.created, updated = os.time(), state = state, reason = reason,
        charged = session.charged == true
    })
end

function RSAIDocSettlements.HasPending(identity)
    for _, entry in pairs(records) do
        if entry.identity == identity and entry.state ~= 'completed'
            and entry.state ~= 'refunded' and entry.state ~= 'rejected' then return true end
    end
    return false
end

function RSAIDocSettlements.Review(session, reason)
    RSAIDocSettlements.Record(session, 'review', reason)
    print(('[rs-aidoc] SETTLEMENT REVIEW id=%s identity=%s account=%s amount=%s reason=%s')
        :format(session.token, session.identity, session.account, session.price, reason))
end

function RSAIDocSettlements.Refund(src, session, reason)
    if not session.charged or session.refundAttempted then return false end
    if RSAIDocBridge.CharacterIdentity(src) ~= session.identity then
        RSAIDocSettlements.Record(session, 'refund_due', reason)
        return false
    end
    -- Persist the intent before crediting. A crash after credit must not replay it.
    if not RSAIDocSettlements.Record(session, 'refunding', reason) then return false end
    session.refundAttempted = true
    local ok, failure = RSAIDocBridge.AddMoney(src, session.account, session.price, reason, session.identity)
    if ok then
        RSAIDocSettlements.Record(session, 'refunded', reason)
    elseif failure == 'rejected' or failure == 'unavailable' then
        session.refundAttempted = false
        RSAIDocSettlements.Record(session, 'refund_due', reason)
    else
        RSAIDocSettlements.Review(session, 'refund outcome uncertain: ' .. tostring(failure))
    end
    return ok
end

local function asSession(id, entry)
    return { token = id, identity = entry.identity, account = entry.account,
        price = entry.amount, created = entry.created, charged = entry.charged }
end

function RSAIDocSettlements.Reconcile(src)
    local identity = RSAIDocBridge.CharacterIdentity(src)
    if not identity then return end
    for id, entry in pairs(records) do
        if entry.identity == identity and entry.state == 'refund_due' then
            RSAIDocSettlements.Refund(src, asSession(id, entry), 'rs-aidoc-recovered-refund')
        end
    end
end

-- In-flight debits, credits and medical dispatches cannot be safely replayed.
for id, entry in pairs(records) do
    if entry.state == 'paid' then
        local session = asSession(id, entry)
        RSAIDocSettlements.Record(session, 'refund_due', 'restart before medical dispatch')
    elseif entry.state == 'charging' or entry.state == 'refunding' or entry.state == 'reviving' then
        RSAIDocSettlements.Review(asSession(id, entry), 'restart during ' .. entry.state)
    end
end

RegisterCommand('aidocsettlements', function(src)
    if src ~= 0 then return end
    for id, entry in pairs(records) do
        if entry.state ~= 'completed' and entry.state ~= 'refunded' and entry.state ~= 'rejected' then
            print(('[rs-aidoc] id=%s identity=%s account=%s amount=%s state=%s reason=%s')
                :format(id, entry.identity, entry.account, entry.amount, entry.state, tostring(entry.reason)))
        end
    end
end, true)

RegisterCommand('aidocsettle', function(src, args)
    if src ~= 0 then return end
    local id, action = args[1], args[2]
    local entry = id and records[id]
    if not entry or entry.state ~= 'review' or (action ~= 'refund' and action ~= 'complete') then
        print('[rs-aidoc] Usage: aidocsettle <review-id> refund|complete (verify provider history first)')
        return
    end
    local session = asSession(id, entry)
    if action == 'complete' then
        RSAIDocSettlements.Record(session, 'completed', 'operator confirmed settlement')
        return
    end
    -- Console authorization confirms that this uncertain operation needs a refund.
    session.charged = true
    if not RSAIDocSettlements.Record(session, 'refund_due', 'operator authorized refund') then return end
    for _, playerId in ipairs(GetPlayers()) do RSAIDocSettlements.Reconcile(tonumber(playerId)) end
end, true)

RSAIDocSettlements.Ready = true

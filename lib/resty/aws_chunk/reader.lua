local resty_sha256 = require('resty.sha256')
local resty_string = require('resty.string')
local err_socket = require( "acid.err_socket" )
local rpc_logging = require('acid.rpc_logging')
local constants = require('resty.aws_chunk.constants')
local aws_authenticator = require('resty.awsauth.aws_authenticator')

local _M = {}
local mt = { __index = _M }

local has_logging = true
local CRLF = '\r\n'

local function log_receive( self, func, ... )
    rpc_logging.reset_start(self.log)
    local buf, errmes = func(... )
    rpc_logging.incr_stat(self.log, 'downstream', 'recvbody', #(buf or ''))

    if errmes ~= nil then
        local err = err_socket.to_code(errmes)
        rpc_logging.set_err(self.log, err)

        return nil, err, 'read body error. ' .. tostring(errmes)
    end

    return buf
end

local function discard_read( self, size )
    return log_receive(self, self.sock.receive, self.sock, size)
end

local function read_body( self, size )
    if size <= 0 then
        return ''
    end

    return log_receive(self, self.sock.receive, self.sock, size)
end

local function read_chunk_meta( self )
    local meta_line, err_code, err_msg = log_receive(self,
        self.sock:receiveuntil(CRLF, {inclusive=true}))
    if err_code ~= nil then
        return nil, err_code, err_msg
    end

    local size, sign = string.match(meta_line, constants.ptn_chunk_meta)
    size = tonumber(size or '', 16)

    if size == nil or size < 0 or sign == nil then
        ngx.log(ngx.INFO, 'invalid chunk metadata:'.. tostring(meta_line))
        return nil, 'InvalidRequest', 'Invalid chunk metadata'
    end

    return {size = size, sign = sign}
end

local function start_chunk( self )
    local meta, err, errmes = read_chunk_meta( self )
    if err ~= nil then
        return nil, err, errmes
    end

    local chunk = {
        size = meta.size,
        sign = meta.sign,
        pos  = 0,
    }

    if self.authenticator ~= nil then
        chunk.sha256 = resty_sha256:new()
    end

    return chunk
end

local function read_chunk_data( self, chunk, size )
    size = math.min(size, chunk.size - chunk.pos)

    local buf, err, errmes = read_body(self, size)
    if err ~= nil then
        return nil, err, errmes
    end

    if chunk.sha256 ~= nil then
        chunk.sha256:update(buf)
    end

    chunk.pos = chunk.pos + #buf

    return buf
end

local function end_chunk(self, chunk)
    -- chunk end, ignore '\r\n'
    local data, err, errmes = discard_read(self, #CRLF)
    if err ~= nil then
        return nil, err, errmes
    end

    if data ~= CRLF then
        return nil, 'InvalidRequest', 'Invalid chunk end'
    end

    if chunk.sha256 ~= nil and chunk.sign ~= constants.fake_signature then
        local bin_sha256 = chunk.sha256:final()
        local hex_sha256 = resty_string.to_hex(bin_sha256)

        local _, err, errmes = self.authenticator:check_chunk_signature(
                                    self.sign_ctx, hex_sha256, chunk.sign)
        if err ~= nil then
            return nil, 'InvalidRequest', tostring(err) .. ':' .. tostring(errmes)
        end
    end

    return nil, nil, nil
end

local function read_from_predata(self, size)
    local data

    if #self.pread_data <= size then
        data = self.pread_data
        self.pread_data = ''
    else
        data = string.sub(self.pread_data, 1, size)
        self.pread_data = string.sub(self.pread_data, #data + 1)
    end

    return data
end

local function read_chunk(self, bufs, size)
    while self.read_eof == false do

        if self.chunk == nil then
            local chunk, err, errmes = start_chunk(self)
            if err ~= nil then
                return nil, err, errmes
            end
            self.chunk = chunk
        end

        local chunk = self.chunk

        if chunk.size > 0 and size <= 0 then
            break
        end

        local read_size = math.min(size, self.block_size)
        local buf, err, errmes = read_chunk_data(self, chunk, read_size)
        if err ~= nil then
            return nil, err, errmes
        end

        table.insert( bufs, buf )

        local buf_size = #buf
        size = size - buf_size
        self.read_size = self.read_size + buf_size

        if chunk.pos == chunk.size then
            local _, err, errmes = end_chunk(self, chunk)
            if err ~= nil then
                return nil, err, errmes
            end
            self.chunk = nil
        end

        if chunk.size == 0 then
            self.read_eof = true
        end
    end

    return bufs
end

local function get_chunk_headers(headers)
    local hdrs = {
        ['x-amz-content-sha256'] = headers['x-amz-content-sha256'],
        ['x-amz-decoded-content-length'] =
            tonumber(headers['x-amz-decoded-content-length']),
    }

    if hdrs['x-amz-content-sha256'] ~= 'STREAMING-AWS4-HMAC-SHA256-PAYLOAD' then
        return
    end

    if hdrs['x-amz-decoded-content-length'] == nil then
        return nil, 'InvalidRequest', 'Invalid x-amz-decoded-content-length'
    end

    return hdrs
end

local function init_chunk_sign(self, sk, bucket, signing_key)
    if type(sk) ~= 'function'
        or type(bucket) ~= 'function'
        or type(signing_key) == nil then

        return nil, 'InvalidArgument', 'Lack chunk signature argument'
    end

    local auth = aws_authenticator.new(sk , bucket, signing_key)

    local ctx, err, errmes = auth:init_seed_signature()
    if err ~= nil then
        if err == 'InvalidSignature' then
            ngx.log(ngx.WARN, 'aws chunk upload ssing non-v4 signatures')
            return
        end
        return nil, err, errmes
    end

    self.sign_ctx = ctx
    self.authenticator = auth
end

function _M.new(_, opts)
    local opts = opts or {}
    local headers = ngx.req.get_headers(0)
    local method = ngx.var.request_method

    local obj = {
        block_size = opts.block_size or 1024 * 1024,

        pread_data = '',

        read_size = 0,

        request_method = method,
        request_headers = headers,
    }

    local body_size, err, errmes = _M.get_body_size(obj)
    if err ~= nil then
        return nil, err, errmes
    end
    obj.body_size = body_size
    obj.read_eof = obj.body_size == obj.read_size

    local sock, err
    if body_size > 0 then
        sock, err = ngx.req.socket()
        if not sock then
            return nil, 'InvalidRequest', err
        end
        sock:settimeout(opts.timeout or 60000)
    end
    obj.sock = sock

    local is_aws_chunk, err, errmes = _M.is_aws_chunk(obj)
    if err ~= nil then
        return nil, err, errmes
    end

    local log_service_key = 'put_client'

    if is_aws_chunk then
        obj.chunk = nil
        obj.aws_chunk = true

        log_service_key = 'aws_chunk_client'

        if opts.check_signature == true then

            local rst, err, errmes = init_chunk_sign(obj, opts.get_secret_key,
                         opts.get_bucket_or_host, opts.shared_signing_key)
            if err ~= nil then
                return nil, err, errmes
            end
        end
    end

    if has_logging then
        obj.log = rpc_logging.new_entry(opts.service_key or log_service_key)
        rpc_logging.add_log(obj.log)
    end

    return setmetatable( obj, mt )
end

local function read_normal(self, bufs, size)
    while size > 0 do

        local read_size = math.min(size,
             self.block_size, self.body_size - self.read_size)

        local buf, err, errmes = read_body(self, read_size)
        if err ~= nil then
            return nil, err, errmes
        end

        table.insert( bufs, buf )

        local buf_size = #buf
        self.read_size = self.read_size + buf_size
        size = size - buf_size

        if self.read_size == self.body_size then
            self.read_eof = true
            break
        end
    end

    return bufs
end

local function _read(self, bufs, size)
    if self.read_eof then
        return bufs
    end

    local _, err_code, err_msg
    if self.aws_chunk then
        _, err_code, err_msg = read_chunk(self, bufs, size)
    else
        _, err_code, err_msg = read_normal(self, bufs, size)
    end

    if err_code ~= nil then
        return nil, err_code, err_msg
    end

    return bufs
end

function _M.read(self, size)
    local bufs = {}

    local data = read_from_predata(self, size)
    if data ~= '' then
        table.insert(bufs, data)
        size = size - #data
    end

    local _, err_code, err_msg = _read(self, bufs, size)
    if err_code ~= nil then
        return nil, err_code, err_msg
    end


    local data
    if #bufs == 1 then
        data = bufs[1]
    else
        data = table.concat(bufs)
    end

    return data
end

function _M.pread(self, size)
    local data = read_from_predata(self, size)
    if data ~= '' then
        size = size - #data
    end

    if size == 0 then
        self.pread_data = data .. self.pread_data
        return data
    end

    local bufs = {data}

    local _, err_code, err_msg = _read(self, bufs, size)
    if err_code ~= nil then
        return nil, err_code, err_msg
    end

    self.pread_data = table.concat(bufs)
    return self.pread_data
end

function _M.get_body_size(self)
    local headers = self.request_headers

    local content_length = tonumber(headers['content-length'])

    if content_length == nil then
        return nil, 'InvalidRequest', 'Content-Length is nil'
    end

    local hdrs, err, errmes = get_chunk_headers(headers)
    if err ~= nil then
        return nil, err, errmes
    end

    if hdrs ~= nil then
        content_length = hdrs['x-amz-decoded-content-length']
    end

    return content_length
end

function _M.is_aws_chunk(self)
    if string.upper(self.request_method) ~= 'PUT' then
        return false
    end

    local hdrs, err, errmes = get_chunk_headers(self.request_headers)

    return hdrs ~= nil, err, errmes
end

function _M.is_eof(self)
    return self.read_eof == true and self.pread_data == ''
end

function _M.rest_body_size(self)
    return self.body_size - self.read_size + #self.pread_data
end

return _M

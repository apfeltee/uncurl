#!/usr/bin/ruby -w

=begin
like curl, but not.
extracts useful, relevant information right away; specifically:
- status
- HTTP redirects (if any)
- HTTP headers
- if document-type is html, also document title, meta manipulators, etc.

todo:
- remove crud. this file mutated from ds.rb, and it shows.
- is there any way to make ruby less.. slow? shit sucks.
=end

require "ostruct"
require "optparse"
require "fileutils"
require "json"
require "oj"
require "http"
require "nokogiri"
require "openssl"

DEFAULT_USERAGENT = "Mozilla/5.0 (Windows NT 00.0; Win00; x00) AppleWebKit/000.00 (KHTML, like Gecko) Chrome/000.0.0.0 Safari/000.0" 
DEFUA_GOOGLE = "Googlebot/2.1 (+http://www.google.com/bot.html)"

# the class that does the actual work.
class UrlCrunch
  def initialize(ds, opts, host, url)
    # the parent initiator class instance. whatever that might be.
    @ds = ds

    # the options as parsed by OptionParser, et al.
    @opts = opts

    @finalhost = host

    # the final url, after following redirects.
    @finalurl = url

    # if, and when, there is a redirect, this will contain the URL.
    @redirection = nil

    # the final response (after following redirects), if any.
    # if a network error (**not** HTTP error) occurs, this will be nil.
    @finalresponse = nil

    # whether the remote URL was retrieved at all - regardless of HTTP status.
    # if a timeout occurs, or the host cannot be resolved, this will be false.
    @remoteisavail = false
    
    # whether the document content type matches something that can be
    # parsed via nokogiri. evidently, this will only be true for text/html
    @pageishtml = false

    # the raw, unparsed document body.
    # will be nil if failed to fetch document.
    @rawpagebody = nil

    # the Nokogiri parser instance.
    # if retrieving the page failed, or @pageishtml == false, then this will be nil.
    @htmldocument = nil

    # quite a few sites have shitty ssl.
    # NB.: don't do this for data transfers, as it skips verification of certificates.
    @sslctx = OpenSSL::SSL::SSLContext.new
    @sslctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

    @netinfoseen = []
  end

  def isavailable
    if @remoteisavail != false then
      return @remoteisavail
    end
    return check_isavail(@finalurl, @finalhost)
  end

  # write to output, or (WIP) a file, etc.
  # key: the message key. should be some sort of identifier
  # fmt: format string. relevant with va
  # va: formatting arguments. only relevant if fmt has modifiers.
  # i.e., 
  #   msgpiece("some-stuff", "snafu has %d foos", foocount)
  #   -> "-- some-stuff: snafu has 42 foos"
  #
  # eventually, the key could be used to store output as a formatted file, such
  # as JSON, et al.:
  # [
  #   {"some-stuff": "snafu has 42 foos"},
  #   ...
  # ]
  def msgpiece(key, fmt, *va)
    $stdout.printf("-- %s: ", key)
    if va.empty? then
      $stdout.write(fmt)
    else
      $stdout.printf(fmt, *va)
    end
    $stdout.write("\n")
  end

  def do_iplookup(host)
    system("ipinfo", host)
  end

  def do_whois(host)
    system("whois", host)
  end


  def print_hostinfo(host)
    hdown = host.downcase
    if !@netinfoseen.include?(hdown) then
      @netinfoseen.push(hdown)
      if @opts.also_iplookup then
        do_iplookup(host)
      end
      if @opts.also_whois then
        do_whois(host)
      end
    end
  end

  def check_isavail(newurl, host, level=0)
    tryagain = false
    parsedurl = Addressable::URI.parse(newurl)
    $stderr.printf("[%s] get(%p) ... ", Time.now.strftime("%T"), newurl)
    begin
      if (@opts.maxredirects > 0) && (level == @opts.maxredirects) then
        raise HTTP::RequestError, "too many redirects"
      end
      print_hostinfo(parsedurl.host)
      # first, retrieve the URL as-is
      @finalresponse = HTTP.headers("User-Agent" => @opts.useragent).timeout(@opts.timeout).get(newurl, ssl_context: @sslctx)
      $stderr.printf("received HTTP status %d %p", @finalresponse.code, @finalresponse.reason)
      if @finalresponse.code == 200 then
        @remoteisavail = true
      else
        #if there is a HTTP redirect, keep a note, and continue with new url
        if (loc = @finalresponse["location"]) != nil then
          tryagain = true
          # build url - since @finalresponse may only contain
          # partial bits, i.e., "/foo/bar"
          if loc.scrub.match?(/^\w+:\/\//) then
            newurl = loc
          else
            newurl = URI.join(@finalurl, loc)
          end
          @redirection = newurl
        else
          @remoteisavail = false
        end
      end
    rescue URI::InvalidURIError => ex
      # not a lot we can do about that here.
      $stderr.printf("could not parse %p: %s\n", newurl, ex.message)
    rescue Errno::ECONNABORTED => ex
       # same. it's fucked.
      $stderr.printf("remote caused a Errno::ECONNABORTED ...\n")
    rescue => ex
      # everything else: maybe check if more clauses could (should?) be added
      $stderr.printf("failed: (%s) %s", ex.class.name, ex.message)
      @remoteisavail = false
    ensure
      $stderr.print("\n")
    end
    if tryagain then
      check_isavail(newurl, parsedurl.host, level+1)
    end
  end

  def have_nodes(nodes)
    return (
      (nodes != nil) &&
      (nodes != []) &&
      (not nodes.empty?)
    )
  end

  # extract the wildly ridiculous meta-refresh shit
  # todo: also check for <noscript>? but who even uses that anymore?
  def deparse_metarefresh(metanode)
    if metanode.attributes.key?("http-equiv") then
      httpequiv = metanode.attributes["http-equiv"].to_s
      if httpequiv.downcase == "refresh" then
        content = metanode["content"]
        _, *rest = content.split(";")
        desturlfrag = rest.join(";").scrub.strip.gsub(/^url\s*=/i, "").strip
        # apparently some browsers allow stuff like content="0; url='http://...'"
        # so we need to check for that
        if (desturlfrag[0] == '\'') || (desturlfrag[0] == '"') then
          desturlfrag = desturlfrag[1 .. -1]
        end
        if (desturlfrag[-1] == '\'') || (desturlfrag[-1] == '"') then
          desturlfrag = desturlfrag[0 .. -2]
        end
        desturlfrag.strip!
        if not desturlfrag.empty? then
          # urls can be relative
          if not desturlfrag.match?(/^\w+:\/\//) then
            begin
              return URI.join(@finalurl, desturlfrag)
            rescue URI::InvalidURIError
            end
          end
          return desturlfrag
        end
      end
    end
    return nil
  end

  def find_metarefresh(metanodes)
    if have_nodes(metanodes) then
      metanodes.each do |metanode|
        if (url = deparse_metarefresh(metanode)) != nil then
          return url
        end
      end
    end
    return nil
  end

  def htmldoc_findmetarefresh()
    metanodes = @htmldocument.css("meta")
    if (url = find_metarefresh(metanodes)) != nil then
      msgpiece("document.meta_redirect", url)
      msgpiece("document.meta_redirtype", "meta-refresh")
    end
  end

  # a surprising number of websites have serveral <title> elements.
  # why? who knows! but it is interesting.
  def htmldoc_findtitle()
    tc = 0
    tnodes = @htmldocument.css("title")
    if have_nodes(tnodes) then
      tall = tnodes.length
      tnodes.each do |tn|
        txt = tn.text
        msgpiece("document title", "[%d of %d] %p", tc+1, tall, txt)
        tc += 1
      end
    end
  end

  # what other bits of HTML stuff is interesting at-a-glance?
  def find_html_shit()
    rawbodylen = @rawpagebody.bytesize
    strippedbody = @rawpagebody.strip
    strippedlen = strippedbody.bytesize
    isempty = ((rawbodylen == 0) || (strippedlen == 0))
    isestr = (isempty ? "is empty" : "")
    msgpiece("response body", "%s%d bytes (%d bytes when stripped)", isestr, rawbodylen, strippedlen)
    @htmldocument = Nokogiri::HTML(@rawpagebody)
    htmldoc_findtitle()
    htmldoc_findmetarefresh()
  end

  def printbody
    idx = 1
    rawlines = []
    @rawpagebody.each_line do |ln|
      rawlines.push(ln)
    end
    $stdout.printf("document body (%d lines):\n", rawlines.length)
    rawlines.each do |ln|
      printable = ln.dump[1 .. -2]
      $stdout.printf("  %03d: %s\n", idx, printable)
      idx += 1
    end
  end

  def main()
    check_isavail(@finalurl, @finalhost)
    res = @finalresponse
    msgpiece("available", @remoteisavail)
    if res != nil then
      ctype = res["content-type"]
      # apparently this is valid for http/2 and up? weird. let's pick the last item.
      if ctype.is_a?(Array) then
        msgpiece("content-type-http2", "server responded with several content-type fields. picking last")
        ctype = ctype.last
      end
      @pageishtml = ((ctype != nil) && ctype.match?(/text\/html/))
      if @redirection != nil then
        msgpiece("redirect", "to %p", @redirection.to_s)
        msgpiece("redirtype", "http-location")
      end
      res.headers.each do |k, v|
        next if v.empty?
        dumped = v.dump[1 .. -2]
        msgpiece("header", "%p = %p", k, dumped)
      end
      @rawpagebody = nil
      begin
        @rawpagebody = res.body.to_s.scrub
      rescue HTTP::TimeoutError => ex
        $stderr.printf("http timeout encountered (%s: %s)\n", ex.class.name, ex.message)
        @rawpagebody = nil
      rescue HTTP::ConnectionError => ex
        $stderr.printf("connection error encountered (%s: %s)\n", ex.class.name, ex.message)
        @rawpagebody = nil
      end
      if @opts.printbody then
        if @rawpagebody != nil then
          printbody()
        end
      end
      if ctype != nil then
        # this is a deliberately placed duplicate field!
        msgpiece("content-type", ctype)
        if @pageishtml then
          find_html_shit()
        end
      end
      return true
    end
    return false
  end
end

class Uncurl
  def initialize(opts)
    @opts = opts
  end

  def do_url(urlstr)
    uri = Addressable::URI.parse(urlstr)
    host = uri.host
  
    hs = UrlCrunch.new(self, @opts, host, urlstr)
    if not hs.main() then
    end
  end

  def do_host(host)
    return do_url(sprintf("http://%s", host))
  end

  def chuckle(arg)
    isuri = arg.match?(/^https?:(\/\/)?/)
    if isuri then
      do_url(arg)
    else
      do_host(arg)
    end
  end
end

begin
  default_timeout = 10
  default_maxredirs = 5
  opts = OpenStruct.new({
    useragent: DEFAULT_USERAGENT,
    timeout: default_timeout,
    maxredirects: default_maxredirs,
    also_iplookup: true,
    also_whois: false,
    writecache: true,
    printbody: false,
  })
  OptionParser.new{|prs|
    prs.on("-t<n>", "--timeout=<n>", "set maximum timeout in seconds. defaults to #{default_timeout}"){|v|
      opts.timeout = v.to_i
    }
    prs.on("-r<n>", "--redirects=<n>", "set maximum redirects. 0 enables inf redirects (NOT RECOMMENDED). defaults to #{default_maxredirs}"){|v|
      opts.maxredirects = v.to_i
    }
    prs.on("-w", "--[no-]whois", "also do a whois lookup. be warned: this could be quite slow."){|v|
      opts.also_whois = v
    }
    prs.on("-i", "--[no-]iplookup", "also do a IP/Host lookup via 'ipinfo'. obviously needs to be in your PATH."){|v|
      opts.also_iplookup = v
    }
    prs.on("-b", "--[no-]printbody", "print document body as-is"){|v|
      opts.printbody = v
    }
    prs.on("-u<useragent>", "--useragent=<useragent>"){|v|
      if %w(g gg goog google).include?(v.downcase) then
        opts.useragent = DEFUA_GOOGLE
      else
        opts.useragent = v
      end
    }
    prs.on("-v", "dummy option. does nothing"){
    }
  }.parse!
  if ARGV.empty? then
    $stderr.printf("usage: %s <url> [<another url> ...]\n", File.basename($0))
  else
    ds = Uncurl.new(opts)
    ARGV.each do |arg|
      ds.chuckle(arg)
    end
  end
end


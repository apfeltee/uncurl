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

# the class that does the actual work.
class UrlCrunch
  def initialize(ds, opts, host)
    @ds = ds
    @opts = opts
    @finalurl = host
    @redirection = nil
    @finalresponse = nil
    @cached_isavailable = nil
    # the raw, unparsed document body
    # will be nil if failed to fetch document
    @pagebody = nil
    # set by find_html_shit
    # if document is not text/html then @document WILL BE NIL!
    @document = nil
    # quite a few sites have shitty ssl.
    @sslctx = OpenSSL::SSL::SSLContext.new
    @sslctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end

  def isavailable
    if @cached_isavailable != nil then
      return @cached_isavailable
    end
    return check_isavail(@finalurl)
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

  def check_isavail(newurl=nil, level=0)
    tryagain = false
    $stderr.printf("[%s] get(%p) ... ", Time.now.strftime("%T"), newurl)
    begin
      if (level == 5) then
        raise HTTP::RequestError, "too many redirects"
      end
      # first, retrieve the URL as-is
      @finalresponse = HTTP.timeout(@opts.timeout).get(newurl, ssl_context: @sslctx)
      $stderr.printf("received HTTP status %d %p", @finalresponse.code, @finalresponse.reason)
      if @finalresponse.code == 200 then
        @cached_isavailable = true
      else
        #if there is a HTTP redirect, keep a note, and continue with new url
        if (loc = @finalresponse["location"]) != nil then
          tryagain = true
          if loc.match?(/^https?:\/\//) then
            newurl = loc
          else
            newurl = URI.join(@finalurl, loc)
          end
          @redirection = newurl
        else
          @cached_isavailable = false
        end
      end
    rescue URI::InvalidURIError => ex
      $stderr.printf("could not parse %p: %s\n", newurl, ex.message)
    rescue Errno::ECONNABORTED => ex
      $stderr.printf("remote caused a Errno::ECONNABORTED ...\n")
      
    rescue => ex
      $stderr.printf("failed: (%s) %s", ex.class.name, ex.message)
      @cached_isavailable = false
    ensure
      $stderr.print("\n")
    end
    if tryagain then
      check_isavail(newurl, level+1)
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
    metanodes = @document.css("meta")
    if (url = find_metarefresh(metanodes)) != nil then
      msgpiece("document.meta_redirect", url)
      msgpiece("document.meta_redirtype", "meta-refresh")
    end
  end

  # a surprising number of websites have serveral <title> elements.
  # why? who knows! but it is interesting.
  def htmldoc_findtitle()
    tc = 0
    tnodes = @document.css("title")
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
    @document = Nokogiri::HTML(@pagebody)
    htmldoc_findtitle()
    htmldoc_findmetarefresh()
  end

  def main()
    check_isavail(@finalurl)
    res = @finalresponse
    msgpiece("available", @cached_isavailable)
    if res != nil then
      ctype = res["content-type"]
      # apparently this is valid for http/2 and up? weird. let's pick the last item.
      if ctype.is_a?(Array) then
        msgpiece("content-type-http2", "server responded with several content-type fields. picking last")
        ctype = ctype.last
      end
      ishtml = ((ctype != nil) && ctype.match?(/text\/html/))
      if @redirection != nil then
        msgpiece("redirect", "to %p", @redirection.to_s)
        msgpiece("redirtype", "http-location")
      end
      res.headers.each do |k, v|
        next if v.empty?
        dumped = v.dump[1 .. -2]
        msgpiece("header", "%p = %p", k, dumped)
      end
      @pagebody = nil
      begin
        @pagebody = res.body.to_s.scrub
      rescue HTTP::TimeoutError => ex
        $stderr.printf("http timeout encountered (%s: %s)\n", ex.class.name, ex.message)
        @pagebody = ""
      rescue HTTP::ConnectionError => ex
        $stderr.printf("connection error encountered (%s: %s)\n", ex.class.name, ex.message)
        @pagebody = ""
      end
      if ctype != nil then
        # this is a deliberately placed duplicate field!
        msgpiece("content-type", ctype)
        if ishtml then
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

  def do_url(url)
    hs = UrlCrunch.new(self, @opts, url)
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
  opts = OpenStruct.new({
    timeout: 10,
  })
  OptionParser.new{|prs|
    prs.on("-t<n>", "--timeout=<n>"){|v|
      opts.timeout = v.to_i
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


require 'cgi'
require 'logger'
require 'net/http'
require 'nokogiri'
require 'pathname'
require 'webrick'

# Extension Methods for Objects
class Object
  def escape_html
    CGI.escape_html(self.to_s)
  end
end

# Extension Methods for Float
class Float
  def to_duration_str
    s = ''
    s << "#{(self/3600).floor}h" if self >= 3600
    s << "#{(self%3600/60).floor}m" if self >= 60
    s << "#{(self%60).round(3)}s"
    return s
  end
end

# Extension Methods for String
class String
  def extract_search_result(pat, nbefore: 5, nafter: 5)
    startp = self.index pat
    return nil unless startp
    return self[([startp - nbefore, 0].max)..(startp+pat.length+nafter-1)]
  end
end

# Extension Methods for Array
class Array
  def second
    self&.[](1)
  end
end

# Extension Methods for Nokogiri XML Element
class Nokogiri::XML::Element
  def to_xpath(attrs: nil)
    xp = if parent.is_a? Nokogiri::HTML::Document then '' else self.parent.to_xpath(attrs: attrs) end
    xp_self = self.name
    if attrs then
      attr_str = attrs.map do |attr|
        value = self.attribute(attr)&.value
        if value then "@#{attr}=#{value.inspect}" else nil end
      end.select do |str| str end.join(' and ')
      xp_self += "[#{attr_str}]" unless attr_str.empty?
    end
    return xp+'/'+xp_self
  end
  def find_ancestor(namepat)
    parent = self.parent
    while not parent.is_a? Nokogiri::HTML::Document
      return parent if parent.name.match? namepat
      parent = parent.parent
    end
    return nil
  end
end

module Kama
  # Logger
  class LogFormatter < Logger::Formatter
    def call(severity, time, progname, msg)
      color_prefix, color_suffix = '', ''
      if Kama.with_color then
        case severity
        when 'ERROR'
          color_prefix, color_suffix = "\033[31m", "\033[30m"
        when 'INFO'
          color_prefix, color_suffix = "\033[36m", "\033[30m"
        when 'WARN'
          color_prefix, color_suffix = "\033[33m", "\033[30m"
        end
      end
      "#{color_prefix}#{progname} #{time.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}#{color_suffix}\n"
    end
  end
  @@logger = Logger.new(STDERR, progname: 'kama.rb', formatter: LogFormatter.new())
  def self.logger
    @@logger
  end
  @@with_color = STDERR.isatty
  def self.with_color
    @@with_color
  end
  def self.with_color=(value)
    @@with_color = value
  end

  # Colorful Writer
  class ColorfulWriter
    @@ansi_color_escape = {:black=>30, :red=>31, :green=>32, :yellow=>33, :blue=>34, :purple=>35, :cyan=>36, :gray=>37}
    attr_reader :file, :with_color, :filter
    def initialize(file, with_color: file.isatty, filter: nil)
      @file, @with_color, @filter = file, with_color, filter
      @indent, @isbol = 0, true
    end

    def print(text)
      if @isbol then
        file.write(' '*@indent) if @indent > 0
        @isbol = false
      end
      text = @filter.call(text) if @filter
      file.write(text)
      return self
    end
    def cprint(text, bold: false, color: :black)
      return print(text) unless @with_color
      esc_color = @@ansi_color_escape[color]
      print("\033[1m") if bold
      print(if esc_color then "\033[#{esc_color}m" else "!!UNKNOWN_COLOR(#{color.inspect})" end)
      print(text)
      print("\033[0m")
      return self
    end
    def newline
      print("\n")
      @isbol = true
      return self
    end

    def bold(text)
      cprint(text, bold: true)
    end
    def green(text)
      cprint(text, color: :green)
    end
    def red(text)
      cprint(text, color: :red)
    end
    def yellow(text)
      cprint(text, color: :yellow)
    end

    def indent(delta)
      @indent += delta
      yield
      @indent -= delta
    end
  end

  # URI Manipulator
  def self.is_in_same_server?(uri, hostname, servport)
    begin
      uri = URI.parse(uri)
      return false unless not uri.scheme or uri.scheme == 'http' or uri.scheme == 'https'
      return true if not uri.scheme and not uri.host
      return (uri.host == hostname and uri.port == servport)
    rescue
      return false
    end
  end
  def self.extract_path(uri)
    URI.parse(uri).path
  end
  def self.href_decode(uri)
    uri = URI.parse(uri)
    return {:path=>uri.path, :query=>Kama.query_decode(uri.query)}
  end
  def self.href_encode(path, query)
    return path.to_s unless query
    querystr = URI.encode_www_form(query.map do |key, value| [key, value.to_s] end)
    return (if path then "#{path}?#{querystr}" else querystr end)
  end
  def self.path_basename(path)
    Pathname.new(path).basename.to_s
  end
  def self.path_dirname(path)
    Pathname.new(path).dirname.to_s
  end
  def self.path_rel2abs(path, relpath)
    path += 'index.html' if path.end_with? '/'
    Pathname.new(path).dirname.join(relpath).to_s
  end
  def self.path_join(*paths)
    path = Pathname.new('')
    paths.each do |p| path = path.join(p.to_s) end
    return path.to_s
  end
  def self.query_decode(query)
    if not query or query == '' then nil else URI.decode_www_form(query).to_h end
  end

  # Query value holder.
  class ValueHolder
    attr_reader :type, :value, :options
    def initialize(type, value, options: nil)
      @type, @value, @options = type.to_s.to_sym, value, options
    end

    def to_s
      @value
    end
    alias :to_str :to_s
    def inspect
      "ValueHolder(type=#{@type}, value=#{@value.inspect}#{if @options then ", options=#{@options}" else '' end})"
    end
    def ==(other)
      other.is_a? ValueHolder and @type == other.type and @value == other.value
    end
  end
  def self.query_normalize(query, mask: false)
    query&.map do |k, v|
      case v
      when ValueHolder
        case v.type
        when :exploit, :marker, :text  # where users can fill arbitrarily.
          v = ''
        when :username, :password
          v = v.type.inspect.upcase if mask
        end
      end
      [k, v]
    end&.to_h
  end

  # Request Manager
  def self.send_request(uri, method: 'GET', query: nil, header: {})
    method, uri = method.upcase, URI.parse(Kama::href_encode(uri, query))
    @@logger.debug("#{method} #{URI.decode(uri.to_s).inspect} ... ")
    raise "unsupported scheme: #{uri.scheme}" unless uri.scheme == 'http'
    conn = Net::HTTP.new(uri.host, uri.port)
    res = case method
    when 'GET'
      conn.get(uri.request_uri, header=header)
    when 'POST'
      conn.post(uri.request_uri, header=header)
    else
      raise "unsupported method: #{method}"
    end
    res[:req_method], res[:req_href], res[:req_header] = method, uri.request_uri, header
    return res
  end
  def self.get(uri, query: nil, header: {})
    Kama.send_request(uri, method: 'GET', query: query, header: header)
  end
  def self.post(uri, query: nil, header: {})
    Kama.send_request(uri, method: 'POST', query: query, header: header)
  end

  # Cookie Wrapper
  class Cookie < Hash
    def set_in_line(line)
      WEBrick::Cookie.parse_set_cookies(line).each do |cookie|
        self[cookie.name] = cookie.value
      end
    end
    def to_s
      self.map do |name, value| WEBrick::Cookie.new(name, value).to_s end.join(';')
    end
  end

  # HTML Color Palette
  @@palette = {
    :white=>'#FFFFFF', :black1=>'#D6D5D5', :black2=>'#929292', :black3=>'#5E5E5E', :black4=>'#000000',
    :blue1=>'#56C1FF', :blue2=>'#00A2FF',:blue3=>'#0076BA', :blue4=>'#004D7F',
  }
  def self.palette
    @@palette
  end

  # Graphviz Wrapper
  class Graphviz
    def self.format_args(args)
      args.map do |k, v|
        v = case v
        when Symbol
          v.to_s
        else
          v.to_s.inspect
        end
        "#{k}=#{v}"
      end.join(',')
    end
    def initialize()
      @nodes, @edges = [], []
      @dot = nil
    end

    def compile(format, progname: 'dot')
      cmdline = "#{progname} -T#{format.to_s}"
      text = IO.popen(cmdline, 'r+', STDERR=>[:child, STDOUT]) do |io|
        io.write self.to_dot
        io.close_write
        io.read
      end
      raise "program #{cmdline.inspect} exited with error #{$?.inspect}: #{text.inspect}" unless $?.to_i == 0
      return text
    end
    def discard_cache
      @dot = nil
    end
    def to_dot
      return @dot if @dot
      @dot = ''
      @dot << "digraph {\n"
      @nodes.each do |node|
        @dot << "  node_#{node[:id]}[#{Graphviz.format_args(node[:args])}];\n"
      end
      @edges.each do |edge|
        @dot << "  node_#{edge[:srcid]} -> node_#{edge[:dstid]}[#{Graphviz.format_args(edge[:args])}];\n"
      end
      @dot << "}"
      return @dot
    end

    def add_edge(srcid, dstid, **args)
      raise "illegal source node ID #{srcid}" unless 0 <= srcid and srcid < @nodes.length
      raise "illegal destination node ID #{dstid}" unless 0 <= dstid and dstid < @nodes.length
      discard_cache
      @edges << {:srcid=>srcid, :dstid=>dstid, :args=>args}
    end
    def add_node(label, **args)
      discard_cache
      args[:label] = label
      node = {:id=>@nodes.length, :args=>args}
      @nodes << node
      return node[:id]
    end
  end

  # Mathematical Functions
  def self.min(a, b)
    return (if a <= b then a else b end)
  end
  class SparseVector < Hash
    def self.zero()
      SparseVector.new
    end
    def self.from_hash(h)
      v = SparseVector.new
      h.each do |k, vk| v[k] = vk end
      return v
    end

    def self.dot(u, v)
      s = 0.0
      u.each do |k, uk|
        vk = v[k]
        s += uk*vk if vk
      end
      return s
    end
    def self.dot_inf(u, v)
      m, n = u.length, v.length
      l = 0.0
      v.each do |k, _|
        l += 1.0 if u.include? k
      end
      return l/((m*n)**0.5)
    end
    def self.jaccard(u, v)
      s = 0.0
      u.each do |k, uk|
        vk = v[k]
        s += 1.0 if vk
      end
      n = u.length
      v.each do |k, _|
        n += 1 unless u.include? k
      end
      s /= n
      return s
    end
    def self.interp(leftvec, rightvec, leftsize, rightsize)
      leftvec.copy.scale!(leftsize).add!(rightvec.copy.scale!(rightsize)).scale!(1.0/(leftsize+rightsize))
    end

    def add!(vec)
      vec.each do |k, vk| self[k] = (self[k] || 0) + vk end
      return self
    end
    alias :copy :clone
    def l2norm
      Math.sqrt(SparseVector.dot(self, self))
    end
    def normalize!
      l2vec = self.l2norm
      self.scale!(1.0/l2vec) if l2vec.abs >= 1e-08
      return self
    end
    def round!(ndigits=0, half: :up)
      self.each do |k, v| self[k] = v.round(ndigits, half: half) end
    end
    def scale!(scale)
      self.each do |k, _| self[k] *= scale end
    end
    def sum
      s = 0.0
      self.each do |_, v| s += v end
      return s
    end
  end

  # Dissimilarity Measures
  class Dissimilarity
    def self.cosine(x, y, xl2norm: nil, yl2norm: nil)
      xl2norm, yl2norm = x.l2norm, y.l2norm
      return 0.0 if xl2norm < 1e-08 and yl2norm < 1e-08
      return 2.0 - 2.0*Kama::SparseVector.dot(x, y)/(xl2norm*yl2norm)
    end
    def self.cosine_jaccard(x, y, xl2norm: nil, yl2norm: nil)
      return 0.0 if x.length == 0 and y.length == 0
      xl2norm, yl2norm = x.l2norm, y.l2norm
      return 0.0 if xl2norm < 1e-08 and yl2norm < 1e-08
      return 2.0 - 2.0*(Kama::SparseVector.dot(x, y)/(xl2norm*yl2norm)*Kama::SparseVector.jaccard(x, y))**2
    end
    def self.jaccard(x, y, xl2norm: nil, yl2norm: nil)
      return 0.0 if x.length == 0 and y.length == 0
      return 1.0 - Kama::SparseVector.jaccard(x, y)
    end
    def self.cosine_inf(x, y, xl2norm: nil, yl2norm: nil)
      return 0.0 if x.length == 0 and y.length == 0
      return 1.0 - Kama::SparseVector.dot_inf(x, y)
    end
  end

  # HTML Embedder
  def self.traverse_domtree(resbody)
    html = Nokogiri::HTML(resbody)
    html.traverse do |node|
      next unless node.is_a? Nokogiri::XML::Element
      if node.name == 'a' then
        begin
          href = Kama.href_decode(node['href'])
          path, query = href[:path], href[:query]
          node['href'] = path
          query&.each do |key, _|
            chnode = Nokogiri::XML::Element.new('input', html)
            attr = Nokogiri::XML::Attr.new(html, 'name')
            attr.value = key
            chnode['name'] = attr
            chnode.parent = node
            yield chnode
          end
        rescue
        end
      end
      yield node
    end
  end
  class HTMLEmbedder
    def self.bot(resbody)
      # Naive method: Bag-Of-Tags.
      vec = Kama::SparseVector.new
      Kama::traverse_domtree(resbody) do |node|
        yield node if block_given?
        index = node.name
        vec[index] = (vec[index] || 0) + 1
      end
      return vec
    end
    def self.full_bot(resbody)
      vec = Kama::SparseVector.new
      forbidset = {}
      Kama::traverse_domtree(resbody) do |node|
        yield node if block_given?
        forbidset[node.parent] = true
        next if forbidset.include? node
        index = node.to_xpath(attrs: ['action', 'href', 'name'])
        vec[index] = (vec[index] || 0) + 1
      end
      return vec
    end
  end

  # Online Clustering
  class Clustering
    class Cluster
      attr_reader :id, :sim_method
      attr_reader :hrefset, :vecset
      attr_accessor :version
      attr_reader :embed_html, :dissim_fn
      def initialize(id, sim_method)
        @id, @sim_method = id, sim_method
        @vecset, @hrefset, @version = {}, {}, 0
        @dissim_fn = Kama::Dissimilarity.method(sim_method)
      end
      def center
        c = Kama::SparseVector.new
        @vecset.each do |v, _| c.add!(v) end
        return c.scale!(1.0/@vecset.length)
      end

      def add_example(vec, path, query)
        @vecset[vec] = vec.l2norm
        @hrefset[Kama.href_encode(path, query)] = true
      end
      def mark_forbidden
        @forbidden = true
      end
      def dissim(vec)
        vecl2norm, mind = vec.l2norm, 1.0
        @vecset.each do |v, vl2norm|
          d = @dissim_fn.call(v, vec, xl2norm: vl2norm, yl2norm: vecl2norm)
          mind = d if d < mind
        end
        return mind
      end
    end

    attr_reader :embed_method, :sim_method, :cluster_size
    attr_reader :history, :clusters
    attr_reader :embed_html
    def initialize(embed_method, sim_method, cluster_size)
      @embed_method, @sim_method, @cluster_size = embed_method, sim_method, cluster_size
      @history, @clusters = [], []
      @embed_html = Kama::HTMLEmbedder.method(@embed_method)
      raise "unknown HTML embedder: #{@method}" unless @embed_html
    end

    def add_example(res, path, query)
      @history << {:res=>res, :path=>path, :query=>query}
      cluster = get_cluster(res)
      if not cluster then
        cluster = Cluster.new(@clusters.length+1, @sim_method)
        @clusters.unshift(cluster)
      end
      vec = @embed_html.call(res.body)
      cluster.add_example(vec, path, query)
      return cluster
    end
    def get_cluster(res, size: @cluster_size)
      vec = @embed_html.call(res.body)
      mind, cid = 1.0, nil
      @clusters.each_with_index do |cluster, id|
        d = cluster.dissim(vec)
        mind, cid = d, id if d < mind and d <= size
      end
      return @clusters[cid] if cid
      return nil
    end
  end

  # Offline Hierarchical Clustering
  def self.hclust(entries, method: :average, sim: :cosine)
    n = entries.length
    sim_fn = Kama::Dissimilarity.method(sim)
    # Initialize the dissimilarity matrix.
    dmat = Array.new(n*n)
    i = 0
    while i < n
      dmat[i*n+i] = 1.0
      j = 0
      while j < i
        dmat[i*n+j] = sim_fn.call(entries[i][:vec], entries[j][:vec])
        j += 1
      end
      i += 1
    end
    # Merge all vectors.
    merges = []
    t = 0
    while true
      t += 1
      # Search the next merged pair.
      target1, target2, d, i = nil, nil, Float::INFINITY, 0
      while i < n
        if dmat[i*n+i] > 0.0 then
          j = 0
          while j < i
            target1, target2, d = j, i, dmat[i*n+j] if dmat[j*n+j] > 0.0 and dmat[i*n+j] < d
            j += 1
          end
        end
        i += 1
      end
      break unless target1 and target2
      # Merge the pair.
      size1, size2 = dmat[target1*n+target1], dmat[target2*n+target2]
      size12 = size1 + size2
      merges << {:pair=>[target1, target2], :sizes=>[size1, size2], :dist=>d}
      # Update the dissimilarity matrix.
      # NOTICE. 0 <= target1 < target2 < n
      k = 0
      case method
      when :average
        while k < target1
          dmat[target1*n+k] = (size1*dmat[target1*n+k] + size2*dmat[target2*n+k])/size12 if dmat[k*n+k] > 0.0
          k += 1
        end
        k += 1
        while k < target2
          dmat[k*n+target1] = (size1*dmat[k*n+target1] + size2*dmat[target2*n+k])/size12 if dmat[k*n+k] > 0.0
          k += 1
        end
        k += 1
        while k < n
          dmat[k*n+target1] = (size1*dmat[k*n+target1] + size2*dmat[k*n+target2])/size12 if dmat[k*n+k] > 0.0
          k += 1
        end
      when :single
        while k < target1
          dmat[target1*n+k] = Kama.min(dmat[target1*n+k], dmat[target2*n+k]) if dmat[k*n+k] > 0.0
          k += 1
        end
        k += 1
        while k < target2
          dmat[k*n+target1] = Kama.min(dmat[k*n+target1], dmat[target2*n+k]) if dmat[k*n+k] > 0.0
          k += 1
        end
        k += 1
        while k < n
          dmat[k*n+target1] = Kama.min(dmat[k*n+target1], dmat[k*n+target2]) if dmat[k*n+k] > 0.0
          k += 1
        end
      else
        raise "unknown method: #{method}"
      end
      dmat[target1*n+target1], dmat[target2*n+target2] = size12, 0.0
    end
    return merges
  end

  # Exploits
  module Exploit
  end

  # Registered Attackers
  @@attackers_onlink = []
  def self.attackers_onlink
    @@attackers_onlink
  end
  @@attackers_ontainted = []
  def self.attackers_ontainted
    @@attackers_ontainted
  end
  @@attackers_optflags = []
  def self.attackers_optflags
    @@attackers_optflags
  end
end

# Load the exploit plugins.
Dir.glob(File.join(File.dirname(__FILE__), 'exploit', '*.rb')) do |path|
  require path
end

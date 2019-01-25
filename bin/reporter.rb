#!/usr/bin/env ruby
require 'json'
require 'nokogiri'
require 'optparse'

$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'kama.rb'

# Parse the command-line options.
embed_method, hclust_method, hclust_sim, veccsv_path, origveccsv_path = :full_bot, :single, :jaccard, nil, nil
filename_filter = /^[0-9]+\.txt/
opt = OptionParser.new
opt.on('--embed TYPE', desc="Specify the embedding method (#{Kama::HTMLEmbedder.methods(false).join(', ')}; default=#{embed_method})") do |v|
  raise "unknown embedding method: #{v}" unless Kama::HTMLEmbedder.methods(false).include? v.to_sym
  embed_method = v.to_sym
end
opt.on('--filter PATTERN', desc="Specify the filename filter (default=#{filename_filter})") do |v|
  begin
    filename_filter = Regexp.new(v)
  rescue
    raise "illegal filename filter: #{v}"
  end
end
opt.on('--method TYPE', desc="Specify the method of the hirarchical clustering (average, single; default=#{hclust_method})") do |v|
  hclust_method = case v
    when 'average', 'single'
      v.to_sym
    else
      raise "unknown hclust method: #{v}"
    end
end
opt.on('--orig-veccsv FILENAME', desc='Specify the CSV path for dumping the original (unnormalized) vectors') do |v| origveccsv_path = v end
opt.on('--sim TYPE', desc="Specify the similarity measure (#{Kama::Dissimilarity.methods(false).join(', ')}; default=#{hclust_sim})") do |v|
  raise "unknown similarity measure: #{v}" unless Kama::Dissimilarity.methods(false).include? v.to_sym
  hclust_sim = v.to_sym
end
opt.on('--veccsv FILENAME', desc='Specify the CSV path for dumping the vectors') do |v| veccsv_path = v end
argv = opt.parse!(ARGV)
raise 'specify the only one dump directory path' unless argv.length == 1
embed_html = Kama::HTMLEmbedder.method(embed_method)

# Collect the vectors.
def extract_domtree(root, node)
  elem = {:name=>node.name, :attrs=>{:action=>node.attributes['action']&.value, :href=>node.attributes['href']&.value, :name=>node.attributes['name']&.value}}
  children = root[node].map do |chnode| extract_domtree(root, chnode) end
  elem[:children] = children if children.length > 0
  return elem
end
ROOTPATH = argv[0]
entries, dumps = [], {}
tagset = {}
Dir.glob(File.join(ROOTPATH, '*')).select do |path| File.basename(path).match? filename_filter end.sort_by do |path| File.basename(path).to_i end.each do |path|
  id = File.basename(path).to_i
  data = File.read(path).split("\n", 3)
  # Calculate the vector and the DOM tree.
  domtree, root = {}, nil
  vec = embed_html.call(data[2]) do |node|
    root = node if node.name == 'html'
    domelem = node.children.select do |chnode| domtree.include? chnode end
    domtree[node] = domelem
  end
  vec.each do |k, _| tagset[k] = true end
  # Ignore if the page is essentially empty.
  next if vec.sum == 0
  # Append the record.
  path_query, code = Kama::href_decode(data[0].undump), data[1].undump
  next unless code == '200'
  entry = {
    :info=>{:id=>id, :path=>path_query[:path], :query=>path_query[:query]},
    :vec=>vec,
  }
  entries << entry
  domtree = extract_domtree(domtree, root)
  dumps[id] = {
    :id=>id, :path=>entry[:info][:path], :query=>entry[:info][:query],
    :res_code=>code,
    :domtree=>domtree,
    :rawres=>data[2],
  }
end
tagset = tagset.sort_by do |k, _| k end.to_h

# Aggregate the duplicated entries.
def undup(entries)
  vecset = {}
  entries.each do |entry|
    (vecset[entry[:vec]] ||= []) << entry[:info]
  end
  return vecset.map do |vec, infolist| {:infolist=>infolist, :hist=>vec, :origvec=>vec, :vec=>vec.copy.normalize!} end
end
entries_undup = undup(entries)

# Dump the entries to CSV if required.
if veccsv_path then
  csv = "path,#{tagset.keys.join(',')}\n"
  entries_undup.each do |entry|
    csv << "#{Kama::href_encode(entry[:infolist][0][:path], entry[:infolist][0][:query]).inspect},#{tagset.map do |k, _| entry[:vec][k] || 0.0 end.join(',')}\n"
  end
  File.write(veccsv_path, csv)
end
if origveccsv_path then
  csv = "path,#{tagset.keys.join(',')}\n"
  entries_undup.each do |entry|
    csv << "#{Kama::href_encode(entry[:infolist][0][:path], entry[:infolist][0][:query]).inspect},#{tagset.map do |k, _| entry[:origvec][k] || 0.0 end.join(',')}\n"
  end
  File.write(origveccsv_path, csv)
end

merges = Kama.hclust(entries_undup, method: hclust_method, sim: hclust_sim)

# Construct the tree from the merge history.
tree = {}
merges.each_with_index do |merge, i|
  leftid, leftsize, rightid, rightsize = merge[:pair][0], merge[:sizes][0], merge[:pair][1], merge[:sizes][1]
  left = tree[leftid] || {:name=>leftid, :parent=>-i, :vec=>entries_undup[leftid][:vec]}
  right = tree[rightid] || {:name=>rightid, :parent=>-i, :vec=>entries_undup[rightid][:vec]}
  tree[leftid] = {:name=>-i, :dist=>merge[:dist], :children=>[left, right], :vec=>Kama::SparseVector.interp(left[:vec], right[:vec], leftsize, rightsize)}
  tree.delete(rightid)
end
def tree_round(tree, ndigits=0, half: :up)
  if tree[:children] then
    tree_round(tree[:children][0], ndigits=ndigits, half: half)
    tree_round(tree[:children][1], ndigits=ndigits, half: half)
  end
  tree[:vec].round!(ndigits, half: half)
  tree[:dist] = tree[:dist].round(ndigits, half: half) if tree[:dist]
  return tree
end
tree = {
  :embed_method=>embed_method,
  :hclust_method=>hclust_method,
  :hclust_sim=>hclust_sim,
  :root=>tree_round(tree[0], ndigits=3),
}

# Construct the node information.
nodes = entries_undup

# Read the online clustering result.
def read_hash(s)
  return nil unless s.start_with? '{' and s.end_with? '}'
  h = {}
  s[1..-2].split(', ').each do |s|
    k, v = s.split('=>')
    h[k.undump] = v
  end
  return h
end
online_clusters = []
begin
  result = File.read(File.join(ROOTPATH, 'result.txt'))
  cluster_lines = result.split("\n").select do |line| line.match? /^  .* :: center={.*}$/ end
  cluster_lines.each do |cluster_line|
    urlset, center_line = cluster_line.strip!.split(' :: center={')
    urlset, center = urlset.split(' | '), read_hash('{'+center_line).map do |k, v| [k, Float(v)] end.to_h
    online_clusters << {:urlset=>urlset, :center=>Kama::SparseVector.from_hash(center).normalize!}
  end
rescue
  Kama.logger.warn("skipped to read result.txt: $!=#{$!}")
end

# Run the server.
SERVADDR = ENV['SERVADDR'] || '127.0.0.1'
SERVPORT = ENV['SERVPORT'] || '9091'
server = WEBrick::HTTPServer.new({:BindAddress=>SERVADDR, :Port=>SERVPORT, :Logger=>Kama.logger})
server.mount_proc('/dump.json', lambda do |req, res|
  raise WEBrick::HTTPStatus::NotFound unless req.path == '/dump.json'
  id = req.query['id'].to_i
  dump = dumps[id]
  raise WEBrick::HTTPStatus::NotFound unless dump
  res.body << JSON.dump(dump)
  raise WEBrick::HTTPStatus::OK
end)
server.mount_proc('/nodes.json', lambda do |req, res|
  raise WEBrick::HTTPStatus::NotFound unless req.path == '/nodes.json'
  res.body << JSON.dump(nodes)
  raise WEBrick::HTTPStatus::OK
end)
server.mount_proc('/online_clusters.json', lambda do |req, res|
  raise WEBrick::HTTPStatus::NotFound unless req.path == '/online_clusters.json'
  res.body << JSON.dump(online_clusters)
  raise WEBrick::HTTPStatus::OK
end)
server.mount_proc('/tree.json', lambda do |req, res|
  raise WEBrick::HTTPStatus::NotFound unless req.path == '/tree.json'
  res.body << JSON.dump(tree)
  raise WEBrick::HTTPStatus::OK
end)
server.mount('/', WEBrick::HTTPServlet::FileHandler, File.join(File.dirname(__FILE__), '..', 'res', 'reporter'))
trap('INT') do
  server.shutdown
end
server.start

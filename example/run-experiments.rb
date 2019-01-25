#!/usr/bin/env ruby
require 'optparse'

def run_fuzzer(args)
  execpath = File.join(File.dirname(__FILE__), '..', 'bin', 'fuzzer.rb')
  cmdline = "#{execpath} #{args.join(' ')}"
  puts "[+] #{cmdline}"
  IO.popen(cmdline, 'r', STDERR=>[:child, STDOUT]) do |io| io.read end
end

class Experiments
  def self.cosine
    # Experiments with Full-BOT vectors and cosine similarities.
    args = ['--embed', 'full_bot', '--sim', 'cosine']
    [
      {'service'=>'gruyere', 'size'=>0.5, 'attacker'=>'XSS'},
      {'service'=>'gruyere', 'username'=>'administrator', 'size'=>0.5, 'attacker'=>'XSS'},
      {'service'=>'weakdays', 'size'=>0.05},
    ].each do |info|
      run_fuzzer(args + info.map do |k, v| ["--#{k}", v] end.flatten)
    end
  end
  def self.jaccard
    # Experiments with Full-BOT vectors and Jaccard similarities.
    args = ['--embed', 'full_bot', '--sim', 'jaccard']
    [
      {'service'=>'gruyere', 'size'=>0.2, 'attacker'=>'XSS'},
      {'service'=>'gruyere', 'username'=>'administrator', 'size'=>0.2, 'attacker'=>'XSS'},
      {'service'=>'weakdays', 'size'=>0.2},
      {'service'=>'webseclab', 'size'=>0.0, 'reqlimit'=>250, 'attacker'=>'XSS'},
    ].each do |info|
      run_fuzzer(args + info.map do |k, v| ["--#{k}", v] end.flatten)
    end
  end
end

targets = Experiments.methods(false)
target = :jaccard
opt = OptionParser.new
opt.on('--target PATTERN', desc="Specify the experiments target (#{targets.join(', ')}; default=#{target})") do |v|
  raise "unknown experiment target: #{target}" unless targets.include? v.to_sym
  target = v.to_sym
end
argv = opt.parse!(ARGV)

Experiments.method(target).call

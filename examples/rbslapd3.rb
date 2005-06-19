#!/usr/local/bin/ruby -w

# This functions like rbdlapd1.rb but uses TOMITA Masahiro's prefork library.
# Advantages over Ruby threading:
# - each client connection is handled in its own process; don't need
#   to worry about Ruby thread blocking (except if one client issues
#   overlapping LDAP operations down the same connection, which is uncommon)
# - better scalability on multi-processor systems
# - better scalability on single-processor systems (e.g. shouldn't hit
#   max FDs per process limit)
# Disadvantages:
# - client connections can't share state in RAM. So our shared directory
#   now has to be read from disk, and flushed to disk after every update.

$:.unshift('../lib')

require 'ldapserver/tcpserver'
require 'ldapserver/connection'
require 'ldapserver/operation'
require 'prefork'		# <http://raa.ruby-lang.org/project/prefork/>
require 'yaml'

# An object to keep our in-RAM database and synchronise it to disk
# when necessary

class Directory
  attr_reader :data

  def initialize(filename)
    @filename = filename
    @stat = nil
    update
  end

  # synchronise with directory on disk (re-read if it has changed)

  def update
    sb = File.stat(@filename)
    return if @stat and @stat.ino == sb.ino and @stat.mtime == sb.mtime
    @stat = sb

    tmp = {}
    begin
      File.open(@filename) { |f| tmp = YAML::load(f.read) }
    rescue Errno::ENOENT
    end
    @data = tmp
  end

  # write back to disk

  def write
    File.open(@filename+".new","w") { |f| f.write(YAML::dump(@data)) }
    File.rename(@filename+".new",@filename)
    @stat = File.stat(@filename)
  end

  # run a block while holding a lock on the database

  def lock
    File.open(@filename+".lock","w") do |f|
      f.flock(File::LOCK_EX)  # will block here until lock available
      yield
    end
  end
end

# We subclass the Operation class, overriding the methods to do what we need

class DirOperation < LDAPserver::Operation
  def initialize(connection, messageID, dir)
    super(connection, messageID)
    @dir = dir
  end

  def search(basedn, scope, deref, filter)
    basedn.downcase!

    case scope
    when LDAPserver::BaseObject
      # client asked for single object by DN
      @dir.update
      obj = @dir.data[basedn]
      raise LDAPserver::NoSuchObject unless obj
      send_SearchResultEntry(basedn, obj) if LDAPserver::Filter.run(filter, obj)

    when LDAPserver::WholeSubtree
      @dir.update
      @dir.data.each do |dn, av|
        next unless dn.index(basedn, -basedn.length)    # under basedn?
        next unless LDAPserver::Filter.run(filter, av)  # attribute filter?
        send_SearchResultEntry(dn, av)
      end

    else
      raise LDAPserver::UnwillingToPerform, "OneLevel not implemented"

    end
  end

  def add(dn, av)
    dn.downcase!
    @dir.lock do
      @dir.update
      raise LDAPserver::EntryAlreadyExists if @dir.data[dn]
      @dir.data[dn] = av
      @dir.write
    end
  end

  def del(dn)
    dn.downcase!
    @dir.lock do
      @dir.update
      raise LDAPserver::NoSuchObject unless @dir.data.has_key?(dn)
      @dir.data.delete(dn)
      @dir.write
    end
  end

  def modify(dn, ops)
    @dir.lock do
      @dir.update
      entry = @dir.data[dn]
      raise LDAPserver::NoSuchObject unless entry
      ops.each do |op, attr, vals|
        case op 
        when :add
          entry[attr] ||= []
          entry[attr] += vals
          entry[attr].uniq!
        when :delete
          if vals == []
            entry.delete(attr)
          else
            vals.each { |v| entry[attr].delete(v) }
          end
        when :replace
          entry[attr] = vals
        end
        entry.delete(attr) if entry[attr] == []
      end
      @dir.write
    end
  end
end

directory = Directory.new("ldapdb.yaml")

ts = PreFork::new(1389)
ts.start do |s|
  begin
    # $stderr.puts "Connection handled by pid #{$$}"
    s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

    LDAPserver::Connection::new(s).handle_requests(DirOperation, directory)

  rescue Exception=>e
    $stderr.print "[#{s.peeraddr[3]}]: #{e}: #{e.backtrace[0]}\n"
  ensure
    s.close
  end
end
#!/usr/bin/env ruby

# This script converts data from old eScholarship into the new eschol5 database.
# It should generally be run on a newly cleaned-out database. This sequence of commands
# should do the trick:
#
# bin/sequel config/database.yaml -m migrations/ -M 0 && \
# bin/sequel config/database.yaml -m migrations/ && \
# ./convert.rb /path/to/allStruct.xml

# Use bundler to keep dependencies local
require 'rubygems'
require 'bundler/setup'

# Remainder are the requirements for this program
require 'date'
require 'json'
require 'nokogiri'
require 'pp'
require 'sequel'
require 'time'
require 'yaml'

ALL_UNITS = Set.new

# Connect to the database into which we'll place data
DB = Sequel.connect(YAML.load_file("config/database.yaml"))

###################################################################################################
# Monkey patches to make Nokogiri even more elegant
class Nokogiri::XML::Node
  def text_at(xpath)
    at(xpath) ? at(xpath).text : nil
  end
end

###################################################################################################
# Model classes for easy object-relational mapping in the database

class Unit < Sequel::Model
  unrestrict_primary_key
end

class UnitHier < Sequel::Model(:unit_hier)
  unrestrict_primary_key
end

class Item < Sequel::Model
  unrestrict_primary_key
end

class UnitItem < Sequel::Model
  unrestrict_primary_key
end

class ItemAuthor < Sequel::Model
  unrestrict_primary_key
end

###################################################################################################
# Insert hierarchy links (skipping dupes) for all descendants of the given unit id.
def linkUnit(id, childMap, done)
  childMap[id].each_with_index { |child, idx|
    if !done.include?([id, child])
      #puts "linkUnit: id=#{id} child=#{child}"
      UnitHier.create(
        :ancestor_unit => id,
        :unit_id => child,
        :ordering => idx,
        :is_direct => true
      )
      done << [id, child]
    end
    if childMap.include?(child)
      linkUnit(child, childMap, done)
      linkDescendants(id, child, childMap, done)
    end
  }
end

###################################################################################################
# Helper function for linkUnit
def linkDescendants(id, child, childMap, done)
  childMap[child].each { |child2|
    if !done.include?([id, child2])
      #puts "linkDescendants: id=#{id} child2=#{child2}"
      UnitHier.create(
        :ancestor_unit => id,
        :unit_id => child2,
        :ordering => nil,
        :is_direct => false
      )
      done << [id, child2]
    end
    if childMap.include?(child2)
      linkDescendants(id, child2, childMap, done)
    end
  }
end

###################################################################################################
# Convert an allStruct element, and all its child elements, into the database.
def convertUnits(el, parentMap, childMap)
  id = el[:id] || el[:ref] || "root"
  #puts "name=#{el.name} id=#{id.inspect} name=#{el[:label].inspect}"

  # Handle regular units
  if el.name == "allStruct"
    Unit.create(
      :id => "root",
      :name => "eScholarship",
      :type => "root",
      :is_active => true,
      :attrs => nil
    )
  elsif el.name == "div"
    attrs = {}
    el[:directSubmit] and attrs[:directSubmit] = el[:directSubmit]
    el[:hide]         and attrs[:hide]         = el[:hide]
    Unit.create(
      :id => id,
      :name => el[:label],
      :type => el[:type],
      :is_active => el[:directSubmit] != "moribund",
      :attrs => JSON.generate(attrs)
    )
    ALL_UNITS << id
  elsif el.name == "ref"
    # handled elsewhere
  end

  # Now recursively process the child units
  el.children.each { |child|
    if child.name != "allStruct"
      id or raise("id-less node with children")
      childID = child[:id] || child[:ref]
      childID or raise("id-less child node")
      parentMap[childID] ||= []
      parentMap[childID] << id
      childMap[id] ||= []
      childMap[id] << childID
    end
    convertUnits(child, parentMap, childMap)
  }

  # After traversing the whole thing, it's safe to form all the hierarchy links
  if el.name == "allStruct"
    puts "Linking units."
    linkUnit("root", childMap, Set.new)
  end
end

###################################################################################################
# Read a large XML file in piecemeal fashion, parsing each record individually. This saves a lot of
# memory, and also lets us get started sooner during testing.
def iterateRecords(filename)
  io = (filename =~ /\.gz$/) ? Zlib::GzipReader.open(filename) : File.open(filename)
  buf = []
  io.each { |line|
    if line =~ /<document>/
      buf = [line]  # clears buf
    elsif line =~ /<\/document>/
      buf << line
      str = buf.join("")
      doc = Nokogiri::XML(str, nil, 'utf-8')
      doc.remove_namespaces!
      yield doc.root
    else
      buf << line.sub("><$", "")  # fix for nonstandard XTF encoding of attributes
    end
  }
  io.close
end

###################################################################################################
# Convert one item
def convertItem(doc)

  # First the item itself
  id = doc.text_at("identifier")
  attrs = {}
  doc.text_at("contentExists") == "yes" and attrs[:contentExists] = true
  doc.text_at("pdfExists") == "yes" and attrs[:pdfExists] = true
  doc.text_at("language") and attrs[:language] = doc.text_at("language")
  doc.text_at("peerReview") == "yes" and attrs[:peerReviewed] = true
  Item.create(
    :id => id,
    :source => doc.text_at("source"),
    :status => doc.text_at("pubStatus") || "unknown",
    :title => doc.text_at("title"),
    :content_type => doc.text_at("format"),
    :genre => doc.text_at("type"),
    :pub_date => doc.text_at("date") || "1901-01-01",
    :eschol_date => doc.text_at("dateStamp") || "1901-01-01", #FIXME
    :attrs => JSON.generate(attrs),
    :rights => doc.text_at("rights") || "public"
  )

  # Link the item's authors
  doc.text_at("creator") and doc.text_at("creator").split(";").each_with_index { |auth, order|
    attrs = {}
    if auth.split(",").length == 2
      attrs[:lname], attrs[:fname] = auth.split(/\s*,\s*/)
    else
      attrs[:organization] = auth
    end
    ItemAuthor.create(
      :item_id => id,
      :ordering => order,
      :attrs => JSON.generate(attrs)
    )
  }

  # Link the item to its unit, and that unit's ancestors.
  if doc.text_at("entityOnly")
    done = Set.new
    aorder = 1000
    doc.text_at("entityOnly").split("|").each_with_index { |unit, order|
      next unless ALL_UNITS.include? unit
      UnitItem.create(
        :unit_id => unit,
        :item_id => id,
        :ordering_of_units => order,
        :is_direct => true
      )
      UnitHier.filter(:unit_id => unit, :is_direct => false).map { |hier| hier.ancestor_unit }.each { |ancestor|
        if !done.include?(ancestor)
          UnitItem.create(
            :unit_id => ancestor,
            :item_id => id,
            :ordering_of_units => aorder,  # maybe should this column allow null?
            :is_direct => false
          )
          aorder += 1
          done << ancestor
        end
      }
    }
  end
end

###################################################################################################
# Main action begins here

# Check command-line format
if ARGV.length != 2
  STDERR.puts "Usage: #{__FILE__} path/to/allStruct.xml path/to/indexDump.xml.gz"
  exit 1
end

# Let the user know what we're doing
puts "Converting units."
startTime = Time.now

# Load allStruct and traverse it
DB.transaction do
  allStructPath = ARGV[0]
  allStructPath or raise("Must specify path to allStruct")
  open(allStructPath, "r") { |io|
    convertUnits(Nokogiri::XML(io, &:noblanks).root, {}, {})
  }
end

# Convert all the items
puts "Converting items."
ALL_UNITs = Set.new(Unit.select(:id).map { |row| row[:id] })
DB.transaction do
  nDone = 0
  iterateRecords(ARGV[1]) { |doc|
    begin
      convertItem(doc)
      nDone += 1
    rescue Exception => e
      puts doc
      raise      
    end
    (nDone % 100) == 0 and puts "#{nDone} done."
  }
  puts "#{nDone} done."
end

# All done.
puts "  Elapsed: #{Time.now - startTime} sec"
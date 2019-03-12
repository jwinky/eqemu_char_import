#!/usr/bin/env ruby

# eqemu_char_import.rb
#
# https://github.com/jwinky/eqemu_char_import
#
# See the README file for instructions and documentation.
#
# This script is designed for Linux.  It is untested on Windows.
#

# -------------------------------
# CONFIGURATION - EDIT THESE
# -------------------------------

# The maximum level to which this script will level a character.
MAX_LEVEL=55

# If multiple copies of this script run simultaneously, it will likely
# corrupt your character data.  To prevent this, the script will do
# nothing and exit with status 2 if the PID file is present, indicating
# that the script is already running.
#
# Modify the path as appropriate for your platform.
PID_FILE_PATH = "/tmp/eqemu_char_import.pid"

# -------------------------------
# END OF CONFIGURATION
# -------------------------------


#
# Initialization
#

require 'csv'
require 'mysql2'
require 'yaml'

# Check PID lock file

if File.exist?(PID_FILE_PATH)
  puts "Error: this script is already running.  Remove the file #{PID_FILE_PATH} if you're sure it's not."
  exit 2
end

# Create PID file
File.write(PID_FILE_PATH, Process.pid)

# Remove PID file when the script exits
at_exit { File.unlink(PID_FILE_PATH) }

# Load MySQL configuration

DB_CONF_FILE=File.absolute_path(File.dirname(__FILE__) + "/dbconfig.yml")
unless File.exist?(DB_CONF_FILE)
  puts "Error: Database config file #{DB_CONF_FILE} does not exist"
  exit 3
end

# Copied from https://github.com/rails/rails/blob/94b5cd3a20edadd6f6b8cf0bdf1a4d4919df86cb/activesupport/lib/active_support/core_ext/hash/keys.rb
class Hash
  def deep_symbolize_keys
    deep_transform_keys { |key| key.to_sym rescue key }
  end
  def deep_symbolize_keys!
    deep_transform_keys! { |key| key.to_sym rescue key }
  end  
  def deep_transform_keys(&block)
    _deep_transform_keys_in_object(self, &block)
  end unless method_defined? :deep_transform_keys
  def deep_transform_keys!(&block)
    _deep_transform_keys_in_object!(self, &block)
  end unless method_defined? :deep_ransform_keys!
  private
  def _deep_transform_keys_in_object(object, &block)
    case object
    when Hash
      object.each_with_object({}) do |(key, value), result|
        result[yield(key)] = _deep_transform_keys_in_object(value, &block)
      end
    when Array
      object.map { |e| _deep_transform_keys_in_object(e, &block) }
    else
      object
    end
  end
  def _deep_transform_keys_in_object!(object, &block)
    case object
    when Hash
      object.keys.each do |key|
        value = object.delete(key)
        object[yield(key)] = _deep_transform_keys_in_object!(value, &block)
      end
      object
    when Array
      object.map! { |e| _deep_transform_keys_in_object!(e, &block) }
    else
      object
    end
  end
end

# All that so we can...
DB_CONFIG=YAML.load_file(DB_CONF_FILE).deep_symbolize_keys!

Mysql2::Client.default_query_options.merge!(:symbolize_keys => true)

# Open script DB and handle errors
begin
  DB_IMPORT = Mysql2::Client.new(DB_CONFIG[:import_script_db])
rescue Mysql2::Error::ConnectionError => e
  puts "Error: unable to connect to import script database"
  puts e.message
  exit 101
end

exit 102 if DB_IMPORT.nil?

# Load pending requests

requests = DB_IMPORT.query("SELECT * FROM requests WHERE status = 'pending' ORDER BY created_at")

if requests.count == 0 
  puts "No pending import requests."
  exit 0
end

# Open EQEmu DB and handle errors

begin
  DB_EQ = Mysql2::Client.new(DB_CONFIG[:eqemu_db])
rescue Mysql2::Error::ConnectionError => e
  puts "Error: unable to connect to EQEmu database"
  puts e.message
  exit 103
end

exit 104 if DB_EQ.nil?


#
# Load whitelisted items
#

itemWhitelist = DB_IMPORT.query("SELECT item_id, name FROM whitelisted_items");
itemWhitelistByName = itemWhitelist.inject({}) {|memo, r| memo[r[:name]] = r[:id]; memo }


#
# Load character data for all queued requests
#

charQuery = DB_EQ.prepare("SELECT id, name, level, gender, race, class, deity FROM character_data WHERE level = 1 AND name IN (?)")
charNames = requests.map {|r| r[:char_name] }
charData  = charQuery.execute(*charNames)
charDataByName = charData.reduce({}) {|memo, r| memo[r[:name]] = r; memo }

goodRequests, badRequests = requests.partition {|r| !!charDataByName[r[:char_name]] }

# Update all "bad" requests at once

if badRequests.count > 0
  badIds = badRequests.map {|r| r[:id] }
  DB_IMPORT.query("UPDATE requests SET processed_at = current_timestamp(), status = 'invalid', error_msg = 'Level 1 character with this name could not be found.  Please create a level 1 character and try again.' WHERE id IN (#{badIds.join(',')})")
end


#
# Setup prepared statements
#

Q_RequestUpdate     = DB_IMPORT.prepare("UPDATE requests SET processed_at = current_timestamp(), status = ?, error_msg = ?, invalid_items = ? WHERE id = ?")

Q_UpdateLevel       = DB_EQ.prepare("UPDATE character_data SET level = ?, exp = ? WHERE id = ?")
Q_SetFullHealthMana = DB_EQ.prepare("UPDATE character_data as cd LEFT JOIN base_data bd ON bd.level = cd.level AND bd.class = cd.class SET cur_hp = bd.hp, cd.mana = bd.mana WHERE id = ?")

Q_ClearInvAndBank   = DB_EQ.prepare("DELETE FROM inventory WHERE charid = ?")
Q_AddInvItem        = DB_EQ.prepare("INSERT INTO inventory (charid, slotid, itemid, charges) VALUES (?, ?, ?, ?)")

Q_ClearSpellbook    = DB_EQ.prepare("DELETE FROM character_spells WHERE id = ?")
Q_AddScribedSpell   = DB_EQ.prepare("INSERT INTO character_spells (id, slot_id, spell_id) VALUES (?, ?, ?)")


#
# Helper/Utility Functions
#

# Maps the outputfile "Location" strings to EQEmu slot IDs
InvOutfileSlotMap = {
  # Worn slots
  'Charm'=>0, 'Ear'=>[1,4], 'Head'=>2, 'Face'=>3, 'Neck'=>5, 'Shoulders'=>6, 'Arms'=>7, 'Back'=>8,
  'Wrist'=>[9,10], 'Range'=>11, 'Hands'=>12, 'Primary'=>13, 'Secondary'=>14, 'Fingers'=>[15,16],
  'Chest'=>17, 'Legs'=>18, 'Feet'=>19, 'Waist'=>20, 'Power Source'=>21, 'Ammo'=>22, 'Held'=>33,
  
  # Inventory
  'General1'=>23,
  'General1-Slot1'=>251, 'General1-Slot2'=>252, 'General1-Slot3'=>253, 'General1-Slot4'=>254, 'General1-Slot5'=>255, 
  'General1-Slot6'=>256, 'General1-Slot7'=>257, 'General1-Slot8'=>258, 'General1-Slot9'=>259, 'General1-Slot10'=>260, 
  'General2'=>24,
  'General2-Slot1'=>261, 'General2-Slot2'=>262, 'General2-Slot3'=>263, 'General2-Slot4'=>264, 'General2-Slot5'=>265, 
  'General2-Slot6'=>266, 'General2-Slot7'=>267, 'General2-Slot8'=>268, 'General2-Slot9'=>269, 'General2-Slot10'=>270, 
  'General3'=>25,
  'General3-Slot1'=>271, 'General3-Slot2'=>272, 'General3-Slot3'=>273, 'General3-Slot4'=>274, 'General3-Slot5'=>275, 
  'General3-Slot6'=>276, 'General3-Slot7'=>277, 'General3-Slot8'=>278, 'General3-Slot9'=>279, 'General3-Slot10'=>280, 
  'General4'=>26,
  'General4-Slot1'=>281, 'General4-Slot2'=>282, 'General4-Slot3'=>283, 'General4-Slot4'=>284, 'General4-Slot5'=>285, 
  'General4-Slot6'=>286, 'General4-Slot7'=>287, 'General4-Slot8'=>288, 'General4-Slot9'=>289, 'General4-Slot10'=>290, 
  'General5'=>27,
  'General5-Slot1'=>291, 'General5-Slot2'=>292, 'General5-Slot3'=>293, 'General5-Slot4'=>294, 'General5-Slot5'=>295, 
  'General5-Slot6'=>296, 'General5-Slot7'=>297, 'General5-Slot8'=>298, 'General5-Slot9'=>299, 'General5-Slot10'=>300, 
  'General6'=>28,
  'General6-Slot1'=>301, 'General6-Slot2'=>302, 'General6-Slot3'=>303, 'General6-Slot4'=>304, 'General6-Slot5'=>305, 
  'General6-Slot6'=>306, 'General6-Slot7'=>307, 'General6-Slot8'=>308, 'General6-Slot9'=>309, 'General6-Slot10'=>310, 
  'General7'=>29,
  'General7-Slot1'=>311, 'General7-Slot2'=>312, 'General7-Slot3'=>313, 'General7-Slot4'=>314, 'General7-Slot5'=>315, 
  'General7-Slot6'=>316, 'General7-Slot7'=>317, 'General7-Slot8'=>318, 'General7-Slot9'=>319, 'General7-Slot10'=>320, 
  'General8'=>30,
  'General8-Slot1'=>321, 'General8-Slot2'=>322, 'General8-Slot3'=>323, 'General8-Slot4'=>324, 'General8-Slot5'=>325, 
  'General8-Slot6'=>326, 'General8-Slot7'=>327, 'General8-Slot8'=>328, 'General8-Slot9'=>329, 'General8-Slot10'=>330, 
  'General9'=>31,
  'General9-Slot1'=>331, 'General9-Slot2'=>332, 'General9-Slot3'=>333, 'General9-Slot4'=>334, 'General9-Slot5'=>335, 
  'General9-Slot6'=>336, 'General9-Slot7'=>337, 'General9-Slot8'=>338, 'General9-Slot9'=>339, 'General9-Slot10'=>340, 
  'General10'=>32,
  'General10-Slot1'=>341, 'General10-Slot2'=>342, 'General10-Slot3'=>343, 'General10-Slot4'=>344, 'General10-Slot5'=>345, 
  'General10-Slot6'=>346, 'General10-Slot7'=>347, 'General10-Slot8'=>348, 'General10-Slot9'=>349, 'General10-Slot10'=>350, 

  # Bank
  'Bank1'=>2000,
  'Bank1-Slot1'=>2031, 'Bank1-Slot2'=>2032, 'Bank1-Slot3'=>2033, 'Bank1-Slot4'=>2034, 'Bank1-Slot5'=>2035, 
  'Bank1-Slot6'=>2036, 'Bank1-Slot7'=>2037, 'Bank1-Slot8'=>2038, 'Bank1-Slot9'=>2039, 'Bank1-Slot10'=>2040, 
  'Bank2'=>2001,
  'Bank2-Slot1'=>2041, 'Bank2-Slot2'=>2042, 'Bank2-Slot3'=>2043, 'Bank2-Slot4'=>2044, 'Bank2-Slot5'=>2045, 
  'Bank2-Slot6'=>2046, 'Bank2-Slot7'=>2047, 'Bank2-Slot8'=>2048, 'Bank2-Slot9'=>2049, 'Bank2-Slot10'=>2050, 
  'Bank3'=>2002,
  'Bank3-Slot1'=>2051, 'Bank3-Slot2'=>2052, 'Bank3-Slot3'=>2053, 'Bank3-Slot4'=>2054, 'Bank3-Slot5'=>2055, 
  'Bank3-Slot6'=>2056, 'Bank3-Slot7'=>2057, 'Bank3-Slot8'=>2058, 'Bank3-Slot9'=>2059, 'Bank3-Slot10'=>2060, 
  'Bank4'=>2003,
  'Bank4-Slot1'=>2061, 'Bank4-Slot2'=>2062, 'Bank4-Slot3'=>2063, 'Bank4-Slot4'=>2064, 'Bank4-Slot5'=>2065, 
  'Bank4-Slot6'=>2066, 'Bank4-Slot7'=>2067, 'Bank4-Slot8'=>2068, 'Bank4-Slot9'=>2069, 'Bank4-Slot10'=>2070, 
  'Bank5'=>2004,
  'Bank5-Slot1'=>2071, 'Bank5-Slot2'=>2072, 'Bank5-Slot3'=>2073, 'Bank5-Slot4'=>2074, 'Bank5-Slot5'=>2075, 
  'Bank5-Slot6'=>2076, 'Bank5-Slot7'=>2077, 'Bank5-Slot8'=>2078, 'Bank5-Slot9'=>2079, 'Bank5-Slot10'=>2080, 
  'Bank6'=>2005,
  'Bank6-Slot1'=>2081, 'Bank6-Slot2'=>2082, 'Bank6-Slot3'=>2083, 'Bank6-Slot4'=>2084, 'Bank6-Slot5'=>2085, 
  'Bank6-Slot6'=>2086, 'Bank6-Slot7'=>2087, 'Bank6-Slot8'=>2088, 'Bank6-Slot9'=>2089, 'Bank6-Slot10'=>2090, 
  'Bank7'=>2006,
  'Bank7-Slot1'=>2091, 'Bank7-Slot2'=>2092, 'Bank7-Slot3'=>2093, 'Bank7-Slot4'=>2094, 'Bank7-Slot5'=>2095, 
  'Bank7-Slot6'=>2096, 'Bank7-Slot7'=>2097, 'Bank7-Slot8'=>2098, 'Bank7-Slot9'=>2099, 'Bank7-Slot10'=>2100, 
  'Bank8'=>2007,
  'Bank8-Slot1'=>2101, 'Bank8-Slot2'=>2102, 'Bank8-Slot3'=>2103, 'Bank8-Slot4'=>2104, 'Bank8-Slot5'=>2105, 
  'Bank8-Slot6'=>2106, 'Bank8-Slot7'=>2107, 'Bank8-Slot8'=>2108, 'Bank8-Slot9'=>2109, 'Bank8-Slot10'=>2110, 
  'Bank9'=>2008,
  'Bank9-Slot1'=>2111, 'Bank9-Slot2'=>2112, 'Bank9-Slot3'=>2113, 'Bank9-Slot4'=>2114, 'Bank9-Slot5'=>2115, 
  'Bank9-Slot6'=>2116, 'Bank9-Slot7'=>2117, 'Bank9-Slot8'=>2118, 'Bank9-Slot9'=>2119, 'Bank9-Slot10'=>2120, 
  'Bank10'=>2009,
  'Bank10-Slot1'=>2121, 'Bank10-Slot2'=>2122, 'Bank10-Slot3'=>2123, 'Bank10-Slot4'=>2124, 'Bank10-Slot5'=>2125, 
  'Bank10-Slot6'=>2126, 'Bank10-Slot7'=>2127, 'Bank10-Slot8'=>2128, 'Bank10-Slot9'=>2129, 'Bank10-Slot10'=>2130, 
  'Bank11'=>2010,
  'Bank11-Slot1'=>2131, 'Bank11-Slot2'=>2132, 'Bank11-Slot3'=>2133, 'Bank11-Slot4'=>2134, 'Bank11-Slot5'=>2135, 
  'Bank11-Slot6'=>2136, 'Bank11-Slot7'=>2137, 'Bank11-Slot8'=>2138, 'Bank11-Slot9'=>2139, 'Bank11-Slot10'=>2140, 
  'Bank12'=>2011,
  'Bank12-Slot1'=>2141, 'Bank12-Slot2'=>2142, 'Bank12-Slot3'=>2143, 'Bank12-Slot4'=>2144, 'Bank12-Slot5'=>2145, 
  'Bank12-Slot6'=>2146, 'Bank12-Slot7'=>2147, 'Bank12-Slot8'=>2148, 'Bank12-Slot9'=>2149, 'Bank12-Slot10'=>2150, 
  'Bank13'=>2012,
  'Bank13-Slot1'=>2151, 'Bank13-Slot2'=>2152, 'Bank13-Slot3'=>2153, 'Bank13-Slot4'=>2154, 'Bank13-Slot5'=>2155, 
  'Bank13-Slot6'=>2156, 'Bank13-Slot7'=>2157, 'Bank13-Slot8'=>2158, 'Bank13-Slot9'=>2159, 'Bank13-Slot10'=>2160, 
  'Bank14'=>2013,
  'Bank14-Slot1'=>2161, 'Bank14-Slot2'=>2162, 'Bank14-Slot3'=>2163, 'Bank14-Slot4'=>2164, 'Bank14-Slot5'=>2165, 
  'Bank14-Slot6'=>2166, 'Bank14-Slot7'=>2167, 'Bank14-Slot8'=>2168, 'Bank14-Slot9'=>2169, 'Bank14-Slot10'=>2170, 
  'Bank15'=>2014,
  'Bank15-Slot1'=>2171, 'Bank15-Slot2'=>2172, 'Bank15-Slot3'=>2173, 'Bank15-Slot4'=>2174, 'Bank15-Slot5'=>2175, 
  'Bank15-Slot6'=>2176, 'Bank15-Slot7'=>2177, 'Bank15-Slot8'=>2178, 'Bank15-Slot9'=>2179, 'Bank15-Slot10'=>2180, 
  'Bank16'=>2015,
  'Bank16-Slot1'=>2181, 'Bank16-Slot2'=>2182, 'Bank16-Slot3'=>2183, 'Bank16-Slot4'=>2184, 'Bank16-Slot5'=>2185, 
  'Bank16-Slot6'=>2186, 'Bank16-Slot7'=>2187, 'Bank16-Slot8'=>2188, 'Bank16-Slot9'=>2189, 'Bank16-Slot10'=>2190, 
  'Bank17'=>2016,
  'Bank17-Slot1'=>2191, 'Bank17-Slot2'=>2192, 'Bank17-Slot3'=>2193, 'Bank17-Slot4'=>2194, 'Bank17-Slot5'=>2195, 
  'Bank17-Slot6'=>2196, 'Bank17-Slot7'=>2197, 'Bank17-Slot8'=>2198, 'Bank17-Slot9'=>2199, 'Bank17-Slot10'=>2200, 
  'Bank18'=>2017,
  'Bank18-Slot1'=>2201, 'Bank18-Slot2'=>2202, 'Bank18-Slot3'=>2203, 'Bank18-Slot4'=>2204, 'Bank18-Slot5'=>2205, 
  'Bank18-Slot6'=>2206, 'Bank18-Slot7'=>2207, 'Bank18-Slot8'=>2208, 'Bank18-Slot9'=>2209, 'Bank18-Slot10'=>2210, 
  'Bank19'=>2018,
  'Bank19-Slot1'=>2211, 'Bank19-Slot2'=>2212, 'Bank19-Slot3'=>2213, 'Bank19-Slot4'=>2214, 'Bank19-Slot5'=>2215, 
  'Bank19-Slot6'=>2216, 'Bank19-Slot7'=>2217, 'Bank19-Slot8'=>2218, 'Bank19-Slot9'=>2219, 'Bank19-Slot10'=>2220, 
  'Bank20'=>2019,
  'Bank20-Slot1'=>2221, 'Bank20-Slot2'=>2222, 'Bank20-Slot3'=>2223, 'Bank20-Slot4'=>2224, 'Bank20-Slot5'=>2225, 
  'Bank20-Slot6'=>2226, 'Bank20-Slot7'=>2227, 'Bank20-Slot8'=>2228, 'Bank20-Slot9'=>2229, 'Bank20-Slot10'=>2230, 
  'Bank21'=>2020,
  'Bank21-Slot1'=>2231, 'Bank21-Slot2'=>2232, 'Bank21-Slot3'=>2233, 'Bank21-Slot4'=>2234, 'Bank21-Slot5'=>2235, 
  'Bank21-Slot6'=>2236, 'Bank21-Slot7'=>2237, 'Bank21-Slot8'=>2238, 'Bank21-Slot9'=>2239, 'Bank21-Slot10'=>2240, 
  'Bank22'=>2021,
  'Bank22-Slot1'=>2241, 'Bank22-Slot2'=>2242, 'Bank22-Slot3'=>2243, 'Bank22-Slot4'=>2244, 'Bank22-Slot5'=>2245, 
  'Bank22-Slot6'=>2246, 'Bank22-Slot7'=>2247, 'Bank22-Slot8'=>2248, 'Bank22-Slot9'=>2249, 'Bank22-Slot10'=>2250, 
  'Bank23'=>2022,
  'Bank23-Slot1'=>2251, 'Bank23-Slot2'=>2252, 'Bank23-Slot3'=>2253, 'Bank23-Slot4'=>2254, 'Bank23-Slot5'=>2255, 
  'Bank23-Slot6'=>2256, 'Bank23-Slot7'=>2257, 'Bank23-Slot8'=>2258, 'Bank23-Slot9'=>2259, 'Bank23-Slot10'=>2260, 
  'Bank24'=>2023,
  'Bank24-Slot1'=>2261, 'Bank24-Slot2'=>2262, 'Bank24-Slot3'=>2263, 'Bank24-Slot4'=>2264, 'Bank24-Slot5'=>2265, 
  'Bank24-Slot6'=>2266, 'Bank24-Slot7'=>2267, 'Bank24-Slot8'=>2268, 'Bank24-Slot9'=>2269, 'Bank24-Slot10'=>2270,

  # Shared Bank
  'SharedBank1'=>2500,
  'SharedBank1-Slot1'=>2531, 'SharedBank1-Slot2'=>2532, 'SharedBank1-Slot3'=>2533, 'SharedBank1-Slot4'=>2534, 'SharedBank1-Slot5'=>2535, 
  'SharedBank1-Slot6'=>2536, 'SharedBank1-Slot7'=>2537, 'SharedBank1-Slot8'=>2538, 'SharedBank1-Slot9'=>2539, 'SharedBank1-Slot10'=>2540, 
  'SharedBank2'=>2501,
  'SharedBank2-Slot1'=>2541, 'SharedBank2-Slot2'=>2542, 'SharedBank2-Slot3'=>2543, 'SharedBank2-Slot4'=>2544, 'SharedBank2-Slot5'=>2545, 
  'SharedBank2-Slot6'=>2546, 'SharedBank2-Slot7'=>2547, 'SharedBank2-Slot8'=>2548, 'SharedBank2-Slot9'=>2549, 'SharedBank2-Slot10'=>2550
}

def expForLevel(level)
  return 0 if level < 1 || level > 100

  # TODO: Use the level_exp_mods table for precision
  return level * level * level * 1000;
end

def setCharLevel(charId, level)
  return unless charId && level

  # Constrain to MAX_LEVEL
  level = MAX_LEVEL if level > MAX_LEVEL

  Q_UpdateLevel.execute(level, expForLevel(level), charId)
  Q_SetFullHealthMana.execute(charId)
end

def importInventory(charId, charLevel, charRace, charClass, charDeity, inventoryData)
  return unless charId && charLevel && inventoryData && inventoryData.length

  # Fix PHPs crappy DB escaping
  inventoryData.gsub!('\&#039;', "'")

  newInventory = CSV.parse(inventoryData, :col_sep => "\t")
  return [] unless newInventory
  return [] unless newInventory.first == ['Location', 'Name', 'ID', 'Count', 'Slots']
  newInventory.shift # Discard field names

  # Remove "Empty" entries
  newInventory = newInventory.reject {|i| i[1] == 'Empty' }

  # TODO: Incorporate item whitelist
  wheres = newInventory.map {|i| "(name = '#{DB_EQ.escape(i[1])}' AND id = #{i[2]})" }

  # Custom SQL enforces race, class, and deity restrictions.  This ensures only usable items
  # from the outfile are imported to prevent deliberate abuse.
  sql = "SELECT id FROM items WHERE minstatus = 0 AND (classes = 0 OR classes & #{charClass} > 0) AND (deity = 0 OR deity & #{charDeity} > 0) AND (races = 0 OR races & #{charRace} > 0) AND (#{wheres.join(' OR ')})"
  usableItemIds = DB_EQ.query(sql).map {|r| r[:id] }

  usableItems, unusableItems = newInventory.partition {|i| usableItemIds.member?(i[2].to_i) }

  # Delete current inventory and bank
  Q_ClearInvAndBank.execute(charId) if usableItems.count

  # Keeps track of slots we've used
  slotMap = InvOutfileSlotMap.dup

  usableItems.each do |i|
    location, name, itemId, charges, slots = i
    next unless location && name && itemId && name != 'Empty'

    availSlots = [slotMap[location]].flatten
    nextSlotId = availSlots.shift
    slotMap[location] = availSlots

    if nextSlotId && nextSlotId > -1
      Q_AddInvItem.execute(charId, nextSlotId, itemId, charges)
    else
      unusableItems.push(i)
    end
  end

  # Return the names of all unusable items
  return unusableItems.map {|i| i[1]}
end

def importSpellbook(charId, charClassNum, spellbookData)
  return unless charId && charClassNum && spellbookData && spellbookData.length

  newSpells = CSV.parse(spellbookData, :col_sep => "\t")
  return unless newSpells

  # Custom query ensures we only get PC class-specific spells.  This prevents
  # malicious outfile data from scribing invalid spells.
  wheres = newSpells.map {|s| "(name = '#{DB_EQ.escape(s.last)}' AND classes#{charClassNum} = #{s.first.to_i})" }
  validSpellsByName = DB_EQ.query("SELECT id, name FROM spells_new WHERE #{wheres.join(' OR ')}").reduce({}) {|memo, r| memo[r[:name]] ||= r[:id]; memo }

  # Clear spellbook
  Q_ClearSpellbook.execute(charId)

  # Re-add spells from the outfile data
  spellSlot = 0

  newSpells.each do |s|
    spellId = validSpellsByName[s.last]

    if spellId && spellId > 0
      Q_AddScribedSpell.execute(charId, spellSlot, spellId) if spellId && spellId > 0
      spellSlot += 1
    end
  end
end


#
# Main processing loop
#

goodRequests.each do |req|
  char = charDataByName[req[:char_name]]
  next unless char

  # Level character
  setCharLevel(char[:id], req[:level]) if char[:level] < req[:level]

  # Import inventory
  invalidItems = importInventory(char[:id], req[:level], char[:race], char[:class], char[:deity], (req[:inventory_outfile] || "").strip)

  # Import spellbook
  importSpellbook(char[:id], char[:class], (req[:spellbook_outfile] || "").strip)

  Q_RequestUpdate.execute('complete', nil, invalidItems.join(', '), req[:id])
end



exit 0

local learning = false

class 'MKMidi' (Midi)

function MKMidi:__init(midi_in_device_name, midi_out_device_name)
   Midi.__init(self, midi_in_device_name, midi_out_device_name)
end

function MKMidi:send_sysex(message_template, number, value)
   local message = {}
   if value < 0 then
      value = 0x4000 + value
   end
   for k,v in pairs(message_template) do
      if v == "cc" then
         table.insert(message, self.midi_channel-1)
      elseif v == "lnn" then
         table.insert(message, number%0x80)
      elseif v == "hnn" then
         table.insert(message, math.floor(number/0x80))
      elseif v == "lvv" then
         table.insert(message, value%0x80)
      elseif v == "hvv" then
         table.insert(message, math.floor(value/0x80))
      else
         table.insert(message, v)
      end
   end
   self:send(message)
end

local old_Group = Group
local function Group(tbl)
   local g = old_Group(tbl)
   local require_large_group = false
   for i, v in ipairs(g.children) do
      v.group = g
      if v.require_large_group then
         require_large_group = v.require_large_group
      end
   end

   if require_large_group then
      g.create_ui = function (self)
         local ret = old_Group.create_ui(self)
         ret.height = self.synth_definition.content_height - 50
         g.ui = ret
         return ret
      end
   end

   return g
end

local old_Parameter = Parameter

local function Parameter(tbl)
   local p = old_Parameter(tbl)

   p.rev_value_callback = tbl.rev_value_callback

   p.send_midi = function (self)
      if self.enabled ~= false then
         old_Parameter.send_midi(self)
      end
      -- Work-around for a bug in Guru
      self.value = self.patch_document_variable.value
   end

   p.to_notify = {}

   p.refresh = function (self)
      for i, id in ipairs(self.to_notify) do
         local p = self.synth_definition.parameters[id]
         local params = {}
         for i, v in ipairs(p.notify_visibility) do
            table.insert(params, self.synth_definition.parameters[v])
         end
         local old = p.enabled
         p.enabled = p.visibility(unpack(params))
         p.ui.visible = p.enabled
         p.group.ui.height = self.synth_definition.content_height
         self.synth_definition.dialog_content.height = self.synth_definition.orig_height
         if old ~= p.enabled then
            if p.enabled and not self.synth_definition.is_loading then
               p:send_midi()
            end
         end
      end
   end

   p.set_value = function (self, value)
      local ret = old_Parameter.set_value(self, value)
      self:refresh()
      return ret
   end

   p.ui_set_value = function (self, value)
      local ret = old_Parameter.ui_set_value(self, value)
      self:refresh()
      return ret
   end

   p.vf_set_value = function (self, value)
      local ret = old_Parameter.vf_set_value(self, value)
      self:refresh()
      return ret
   end

   p.create_ui = function (self)
      local ret = old_Parameter.create_ui(self)
      self.ui = ret
      ret.visible = self.enabled
      return ret
   end

   p.initialize = function (self, ...)
      old_Parameter.initialize(self, ...)

      if self.notify_visibility ~= nil and self.visibility ~= nil then
         for i, v in ipairs(self.notify_visibility) do
            if self.synth_definition.parameters[v] == nil then
               print(("Wrong id '%s'"):format(v))
            end
            table.insert(self.synth_definition.parameters[v].to_notify, self.id)
         end
         self.enabled = false
      else
         self.enabled = true
      end
   end


   p.notify_visibility = tbl.notify_visibility
   p.visibility = tbl.visibility

   p.require_large_group = tbl.notify_visibility ~= nil and tbl.visibility ~= nil
   return p
end

class 'MKDefinition' (SynthDefinition)

function print_diff(old, new)
   assert(#old, #new)
   for i, v in ipairs(old) do
      if new[i] ~= v then
         print(("Changed 0x%02x from %02x to %02x"):format(i, v, new[i]))
      end
   end
end

function print_dump(message)
   print(string.char(unpack(message, 1, 9)))
   for i = 0, #message/8-1 do
      local line = ("%02x|%02x %02x %02x %02x %02x %02x %02x %02x"):format(i, unpack(message, 1+8*i, 8+8*i))
      print(line)
   end
   local lastline = ("%02x|"):format(#message/8)
   for k = 1,#message%8 do
      lastline = lastline .. ("%02x "):format(message[k+8*math.floor(#message/8)])
   end
   print(lastline)
end

function MKDefinition:decode_data(message)
   assert(message[1] == 0xF0 and message[#message] == 0xF7)
   local encoded = {}
   for i = 6, #message-1 do
      encoded[i-5] = message[i]
   end
   local out = {}
   for i, v in ipairs(encoded) do
      if i%8 == 1 then
         for j = 1, 8 do
            if v%2 == 1 then
               out[7*(i-1)/8+j] = 0x80
            else
               out[7*(i-1)/8+j] = 0x00
            end
            v = math.floor(v / 2)
         end
      else
         out[i-math.floor((i+7)/8)] = out[i-math.floor((i+7)/8)] + v
      end
   end
   return out
end

function MKDefinition:got_input(message)
   if message[1] == 0xF0 then
      self.buffer = nil
      if message[#message] == 0xF7 then
         self:receive_sysex(message)
      else
         self. buffer = {}
         for i, v in ipairs(message) do
            self.buffer[i] = v
         end
      end
   else
      assert(self.buffer ~= nil)
      local os = #(self.buffer)
      for i, v in ipairs(message) do
         self.buffer[os+i] = v
      end
      if self.buffer[#(self.buffer)] == 0xF7 then
         message = self.buffer
         self.buffer = nil
         self:receive_sysex(message)
      end
   end
end  

function MKDefinition:__init(tbl)
   self.event_root = {}
   self.data_map = tbl.data_map
   self.data_map_keys = {}
   for k, v in pairs(self.data_map) do
      table.insert(self.data_map_keys, k)
   end
   table.sort(self.data_map_keys)
   self.known_data_map = {}
   self.tool = renoise.tool()
   SynthDefinition.__init(self, tbl)
end

function MKDefinition:create_ui()
   local ui = SynthDefinition.create_ui(self)
   self.orig_height = ui.height
   return ui
end

function MKDefinition:receive_midi(message)
   if message[1] >= 0xC0 and message[1] <= 0xCF then
      -- program change
      self:refresh_data()
   end
end

function MKDefinition:refresh_data_callback()
   self.tool:remove_timer({self, MKDefinition.refresh_data_callback})
   self.midi.midi_out_device:send({0xF0, 0x42, 0x30, 0x7e, 0x10, 0xF7})
end

function MKDefinition:refresh_data()
   if self.tool:has_timer({self, MKDefinition.refresh_data_callback}) then
      self.tool:remove_timer({self, MKDefinition.refresh_data_callback})
   end
   self.tool:add_timer({self, MKDefinition.refresh_data_callback},
                       300)
end


function MKDefinition:receive_sysex(message)
   local params = self:find_param_from_sysex(message)

   if params ~= nil then
      local found_one_enabled = false
      for y, param in ipairs(params) do
         local enabled = param.enabled
         local ok = true
         if enabled ~= nil then
            ok = enabled
         end
         if ok then
            if self.known_data_map[param.id] == nil and learning then
               print("Missing data map for "..  param.id)
               self:refresh_data()
            end
            found_one_enabled = true
            assert(#(param.sysex_message_template) == #message)
            local vv = 0
            for i, v in ipairs(param.sysex_message_template) do
               if v == "lvv" then
                  vv = vv + message[i]
               elseif v == "hvv" then
                  vv = vv + 0x80*message[i]
               end
            end
            if vv >= 0x2000 then
               vv = vv - 0x4000
            end
            local item_values = param.item_values
            if item_values ~= nil then
               for j, x in ipairs(item_values) do
                  if x == vv then
                     if param.value ~= j then
                        param:set_value(j)
                     end
                     break
                  end
               end
            else
               local rev = param.rev_value_callback
               if rev ~= nil then
                  local new_v = rev(vv)
                  if param.value ~= new_v then
                     param:set_value(new_v)
                  end
               else
                  if param.value ~= vv then
                     param:set_value(vv)
                  end
               end
            end
         end
      end
      if not found_one_enabled then
         self:refresh_data()
         local s = {}
         for i, v in ipairs(message) do
            s[i] = ("%02x"):format(v)
         end
         print(unpack(s))
      end
   else
      assert(message[#message] == 0xF7)
      local recognized = true
      local header = {0xF0, 0x42, 0x30, 0x7e, 0x40}
      for i, v in ipairs(header) do
         if message[i] ~= v then
            recognized = false
            break
         end
      end
      if recognized then
         self.is_loading = true
         local data = self:decode_data(message)
         for i, k in ipairs(self.data_map_keys) do
            local v = self.data_map[k]
            if type(v) == "string" then
               if self.parameters[v] == nil then
                  print(("Bad parameter '%s'"):format(v))
               else
                  if self.parameters[v].min_value < 0 then
                     print(("Not expecting a string for '%s'"):format(v))
                  end
                  self.known_data_map[self.parameters[v].id] = true
                  local enabled = self.parameters[v].enabled
                  local ok = true
                  if enabled ~= nil then
                     ok = enabled
                  end
                  if ok then
                     local item_values = self.parameters[v].item_values
                     if item_values ~= nil then
                        for j, x in ipairs(item_values) do
                           if x == data[k] then
                              if self.parameters[v].value ~= j then
                                 self.parameters[v]:set_value(j)
                              end
                           break
                           end
                        end
                     else
                        if self.parameters[v].value ~= data[k] then
                           self.parameters[v]:set_value(data[k])
                        end
                     end
                  end
               end
            else
               for q, w in ipairs(v(data[k], data)) do
                  if self.parameters[w[1]] == nil then
                     print(("Bad parameter '%s'"):format(w[1]))
                  else
                     self.known_data_map[w[1]] = true
                     local enabled = self.parameters[w[1]].enabled
                     local ok = true
                     if enabled ~= nil then
                        ok = enabled
                     end
                     if ok then
                        local item_values = self.parameters[w[1]].item_values
                        if item_values ~= nil then
                           for j, x in ipairs(item_values) do
                              if x == w[2] then
                                 if self.parameters[w[1]].value ~= j then
                                    self.parameters[w[1]]:set_value(j)
                                 end
                                 break
                              end
                           end
                        else
                           if self.parameters[w[1]].value ~= w[2] then
                              self.parameters[w[1]]:set_value(w[2])
                           end
                        end
                     end
                  end
               end
            end
         end
         self.is_loading = false
         if learning then
            --print_dump(data)
            if self.old_data ~= nil then
               print_diff(self.old_data, data)
            end
            self.old_data = data
         end
      elseif learning then
         local s = {}
         for i, v in ipairs(message) do
            s[i] = ("%02x"):format(v)
         end
         print(unpack(s))
         self:refresh_data()
      end
   end
end

function MKDefinition:add_event_parser(message, param)
   local cur = self.event_root
   for i, v in ipairs(message) do
      if v == "cc" then
         v = self.midi.midi_channel-1
      elseif v == "hnn" then
         v = math.floor(param.number/0x80)
      elseif v == "lnn" then
         v = param.number%0x80
      end
      if cur[v] == nil then
         cur[v] = {}
      end
      cur = cur[v]
   end
   if cur["parameters"] == nil then
      cur["parameters"] = {param}
   else
      cur["parameters"][1+#(cur["parameters"])] = param
   end
end

function MKDefinition:find_param_from_sysex_rec(message, pos, cur)
   if pos > #message then
      return cur["parameters"]
   end
   local next = cur[message[pos]]
   if next ~= nil then
      local ret = self:find_param_from_sysex_rec(message, pos+1, next)
      if ret ~= nil then
         return ret
      end
   end
   next = cur["hvv"]
   if next ~= nil then
      return self:find_param_from_sysex_rec(message, pos+1, next)
   end
   next = cur["lvv"]
   if next ~= nil then
      return self:find_param_from_sysex_rec(message, pos+1, next)
   end
   return nil
end

function MKDefinition:find_param_from_sysex(message)
   return self:find_param_from_sysex_rec(message, 1, self.event_root)
end

function MKDefinition:collect_parameters(node)
   if type(node) == "Parameter" then
      self:add_event_parser(node.sysex_message_template, node)
      return
   end
   if node.children ~= nil then
      for i, child in ipairs(node.children) do
         self:collect_parameters(child)
      end
   end
end

function MKDefinition:initialize()
   SynthDefinition.initialize(self)
   self:collect_parameters(self)
end

function MKDefinition:init_midi()
   local midi_out_device = self.preferences.midi_out_device_name.value
   local midi_in_device = self.preferences.midi_in_device_name.value
   
   if midi_out_device == nil then
      midi_out_device = guru.preferences.midi_out_device_name.value
   end

   if midi_in_device == nil then
      midi_in_device = guru.preferences.midi_in_device_name.value
   end 

   self.midi = MKMidi(midi_in_device, midi_out_device)
   self.midi:set_midi_channel(self.preferences.midi_out_channel.value)

   local found = false
   for i, v in ipairs(renoise.Midi.available_input_devices()) do
      if self.midi.midi_in_device_name == v then
         found = true
      end
   end
   if not found then
      self.midi.midi_in_device_name = renoise.Midi.available_input_devices()[1]
   end

   self.midi_in_device = renoise.Midi.create_input_device(self.midi.midi_in_device_name,
                                                          {self, self.receive_midi},
                                                          {self, self.got_input})
end

function range(from, to)
   local out = {}
   for i = 1, to-from+1 do
      out[i] = from+i-1
   end
   return out
end

local knob_values = {"none", "portamento", "osc1 c1", "osc1 c2", "osc2 semi",
                     "osc2 tune", "osc1 lvl", "osc2 lvl", "noise lvl", "cutoff1", "reso1",
                     "filt1 bal", "eg1 int1", "cutoff2", "reso2", "eg1 int2", "level",
                     "panpot", "ws depth", "attack1", "decay1", "sustain1", "release1",
                     "attack2", "decay2", "sustain2", "release2",
                     "lfo1 freq", "lfo2 freq", "p int1", "p int2", "p int3", "p int4", "p int5",
                     "p int6", "hi eq gain", "lo eq gain", "fx1 D/W", "fx1 ctrl1",
                     "fx1 ctrl2", "fx2 D/W", "fx2 ctrl1", "fx2 ctrl2", "gate time",
                     "oct range", "arp swing", "vc t1 lvl", "vc t2 lvl", 
                     "vc hpf lvl", "vc fc ofst", "vc reso", "vc ef sens",
                     "vc fc mint", "vc dir lvl", "vc level"}

local patch_sources = {"EG1", "EG2", "EG3",
                       "LFO1", "LFO2", "velocity",
                       "p bend", "mod wheel",
                       "key track", "MIDI 1", "MIDI 2", "MIDI 3"}

local patch_dests = {"pitch", "osc2 tune", "osc1 c1", "osc1 level",
                     "osc2 level", "noise level", "filt1 bal",
                     "cutoff1", "reso1", "cutoff2", "ws depth",
                     "level", "panpot", "lfo1 freq",
                     "lfo2 freq", "portamento", "osc1 c2", "eg1 int1",
                     "key track 1", "reso 2", "eg1 int2", "key track 2",
                     "attack1", "decay1", "sustain1", "release1",
                     "attack2", "decay2", "sustain2", "release2",
                     "attack3", "decay3", "sustain3", "release3",
                     "p int1", "p int2", "p int3", "p int4", "p int5", "p int6"}

local fx_types = {"off", "compressor", "filter", "band eq", "distortion",
                  "decimator", "delay", "lcr delay", "pan delay", "mod delay",
                  "tape echo", "chorus", "flanger", "vibrato",
                  "phaser", "tremolo", "ring mod", "grain sft"}

local sync_notes = {"8/1", "4/1", "2/1", "1/1", "3/4", "1/2", "3/8", "1/4", "3/16", "1/6",
                    "1/12", "1/16", "1/24", "1/32", "1/64"}

function get_timbre_sections(timbre)
   local old_Parameter = Parameter
   local function Parameter(tbl)
      tbl.id = tbl.id .. ("_%d"):format(timbre)
      if tbl.notify_visibility ~= nil then
         for i, v in ipairs(tbl.notify_visibility) do
            tbl.notify_visibility[i] = ("%s_%d"):format(v, timbre)
         end
      end
      return old_Parameter(tbl)
   end

   local r = {Section {
                 sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x10 + timbre, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
                 name = ("Timbre %d osc"):format(timbre),
                 Group {
                    name = "Voice",
                    Parameter {
                       name = "Assign",
                       id = "assign_voice",
                       items = {"mono 1", "mono 2", "poly"},
                       item_values = range(0, 2),
                       default_value = 3,
                       number = 0x0b,
                    },
                 },
                 Group {
                    name = "Unisson",
                    
                    Parameter {
                       name = "Mode",
                       id = "unisson_mode",
                       number = 0x08,
                       items = {"off", "2 voice", "3 voice", "4 voice"},
                       item_values = range(0, 3),
                    },
                    Parameter {
                       name = "Detune",
                       id = "unisson_detune",
                       number = 0x09,
                       default_value = 0,
                       max_value = 0x63,
                    },
                    Parameter {
                       name = "Spread",
                       id = "unisson_spread",
                       number = 0x0a,
                       default_value = 0,
                       max_value = 0xf7,
                    },
                 },
                 Group {
                    name = "Pitch",
                    Parameter {
                       name = "Analog tune",
                       id = "analog_tune",
                       max_value = 0x7f,
                       number = 0x13,
                    },
                    Parameter {
                       name = "Transpose",
                       min_value = -48,
                       max_value = 48,
                       default_value = 0,
                       id = "transpose",
                       number = 0x14,
                    },
                    Parameter {
                       name = "Detune",
                       min_value = -50,
                       max_value = 50,
                       default_value = 0,
                       id = "detune",
                       number = 0x15,
                    },
                    Parameter {
                       name = "Vib int",
                       id = "vib_int",
                       number = 0x16,
                       min_value = -63,
                       max_value = 63,
                       default_value = 10,
                    },
                    Parameter {
                       name = "P bend",
                       id = "p_bend",
                       number = 0x10,
                       min_value = -12,
                       max_value = 12,
                       default_value = 2,
                    },
                    Parameter {
                       name = "Portamento",
                       id = "portamento",
                       number = 0x11,
                       min_value = 0,
                       max_value = 127,
                       default_value = 0,
                    },
                 },
                 Group {
                    name = "Oscillator 1",
                    Parameter {
                       name = "Wave",
                       id = "wave_1",
                       items = {"saw", "pulse", "triangle", "sine", "formant",
                                "noise", "pcm/dwgs", "audio in",},
                       item_values = range(0, 7),
                       number = 0x17,
                    },
                    Parameter {
                       name = "Osc mod",
                       id = "osc_mod_1",
                       items = {"waveform", "cross", "unisson", "vpm"},
                       item_values = range(0, 3),
                       number = 0x18,
                    },

                    Parameter {
                       name = "Waveform (C1)",
                       id = "osc1_waveform",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 3) and osc_mod.value == 1
                       end
                    },

                    Parameter {
                       name = "Wave shape (C1)",
                       id = "osc1_wave_shape",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 4 and osc_mod.value == 1
                       end
                    },

                    Parameter {
                       name = "Pulse width (C1)",
                       id = "osc1_pulse_width",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 2 and osc_mod.value == 1
                       end
                    },

                    Parameter {
                       name = "Formant width (C1)",
                       id = "osc1_formant_width",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 5 and osc_mod.value == 1
                       end
                    },
                    Parameter {
                       name = "Formant width (C2)",
                       id = "osc1_formant_sft",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x1a,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 5 and osc_mod.value == 1
                       end
                    },

                    Parameter {
                       name = "Reso (C1)",
                       id = "osc1_reso",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 6 and osc_mod.value == 1
                       end
                    },
                    Parameter {
                       name = "Bal (C2)",
                       id = "osc1_bal",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x1a,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 6 and osc_mod.value == 1
                       end
                    },


                    Parameter {
                       name = "Gain (C1)",
                       id = "osc1_gain",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 8 and osc_mod.value == 1
                       end
                    },

                    Parameter {
                       name = "Detune (C1)",
                       id = "osc1_detune",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 2 or wave.value == 3 or wave.value == 4) and osc_mod.value == 3
                       end
                    },

                    Parameter {
                       name = "Mod depth (C1)",
                       id = "osc1_mod_depth",
                       max_value = 127,
                       number = 0x19,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 2 or wave.value == 3 or wave.value == 4) and (osc_mod.value == 2 or osc_mod.value == 4)
                       end
                    },

                    Parameter {
                       name = "LFO mod depth (C2)",
                       id = "osc1_lfo1_mod_depth",
                       max_value = 127,
                       number = 0x1a,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 2 or wave.value == 3 or wave.value == 4) and (osc_mod.value == 1 or osc_mod.value == 2)
                       end
                    },

                    Parameter {
                       name = "Phase (C2)",
                       id = "osc1_phase",
                       max_value = 127,
                       number = 0x1a,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 2 or wave.value == 3 or wave.value == 4) and osc_mod.value == 3
                       end
                    },

                    Parameter {
                       name = "Harmonic (C2)",
                       id = "osc1_harmonic",
                       max_value = 127,
                       number = 0x1a,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return (wave.value == 1 or wave.value == 2 or wave.value == 3 or wave.value == 4) and osc_mod.value == 4
                       end
                    },

                    Parameter {
                       name = "Wave sel (C2)",
                       id = "osc1_sample",
                       items = {"ac piano", "rose ep", "wurly ep", "vpm ep1", "vpm ep2",
                                "clav 1", "clav 2", "clav 3",
                                "organ 1", "organ 2", "organ 3", "m1 organ", "full organ",
                                "vox organ",
                                "pipe organ", "strings", "brass",
                                "guitar 1", "guitar 2", "bass 1", "bass 2", "bass 3",
                                "bell 1", "bell 2", "bell 3",
                                "synpad 1", "synpad 2", "synpad 3",
                                "synsine 1", "synsine 2", "synsine 3", "synsine 4",
                                "synsine 5", "synsine 6", "synsine 7", 
                                "synwave 1", "synwave 2", "synwave 3", "synwave 4",
                                "synwave 5", "synwave 6", "synwave 7", 
                                "synwire 1", "synwire 2", "synwire 3", "synwire 4",
                                "5th saw", "5th square",
                                "digi 1", "digi 2", "digi 3", "digi 4", "digi 5",
                                "digi 6", "digi 7", "digi 8", "digi 9",
                                "synvox 1", "synvox 2", "endless",
                                "noise 1", "noise 2", "noise 3", "noise 4"},
                       item_values = range(0, 0x3f),
                       number = 0x1b,
                       notify_visibility = {"wave_1", "osc_mod_1"},
                       visibility = function (wave, osc_mod)
                          return wave.value == 7 and osc_mod.value == 1
                       end
                    },
 
                 },
                 Group {
                    name = "Oscillator 2",
                    Parameter {
                       name = "Wave",
                       id = "wave_2",
                       items = {"saw", "pulse", "triangle", "sine"},
                       item_values = range(0, 3),
                       number = 0x20,
                    },
                    Parameter {
                       name = "Osc mod",
                       id = "osc_mod_2",
                       items = {"off", "ring", "sync", "ring+sync"},
                       item_values = range(0, 3),
                       number = 0x21,
                    },
                    Parameter {
                       name = "Semitone",
                       id = "osc2_semi",
                       max_value = 24,
                       min_value = -24,
                       default_value = 0,
                       number = 0x22,
                    },
                    Parameter {
                       name = "Tune",
                       id = "osc2_tune",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x23,
                    },
                 },
                 Group {
                    name = "mixer",
                    Parameter {
                       name = "Osc1",
                       id = "osc1_lvl",
                       max_value = 127,
                       default_value = 127,
                       number = 0x28,
                    },
                    Parameter {
                       name = "Osc2",
                       id = "osc2_lvl",
                       max_value = 127,
                       number = 0x29,
                    },
                    Parameter {
                       name = "Noise",
                       id = "noise_lvl",
                       max_value = 127,
                       number = 0x2a,
                    },
                    Parameter {
                       name = "Punch",
                       id = "punch_lvl",
                       max_value = 127,
                       number = 0x57,
                    },
                 },
                 Group {
                    name = "Drive/WS",
                    Parameter {
                       name = "Type",
                       id = "drive_type",
                       items = {"off", "drive", "decimator", "hard clip", "oct saw", "multi tri",
                                "multi sin", "sb psc saw", "sb psc tri", "sb psc sin",
                                "lvl boost"},
                       item_values = range(0, 10),
                       number = 0x51,
                    },
                    Parameter {
                       name = "Position",
                       id = "drive_position",
                       items = {"pre filt1", "pre amp"},
                       item_values = {0, 1},
                       number = 0x52,
                    },
                    Parameter {
                       name = "Depth",
                       id = "drive_depth",
                       max_value = 127,
                       number = 0x54,
                    },
                 }
              },                       
              Section {
                 name = ("Timbre %d filters"):format(timbre),
                 sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x10 + timbre, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
                 Group {
                    name = "Filter 1",
                    Parameter {
                       name = "Cutoff",
                       id = "filt1_cutoff",
                       max_value = 127,
                       number = 0x32,
                    },
                    Parameter {
                       name = "Resonance",
                       id = "filt1_reso",
                       max_value = 127,
                       number = 0x33,
                    },
                    Parameter {
                       name = "Type",
                       id = "filt1_type",
                       max_value = 127,
                       default_value = 127,
                       number = 0x31,
                    },
                    Parameter {
                       name = "EG1 int",
                       id = "filt1_eg1_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x34,
                    },
                    Parameter {
                       name = "Key track",
                       id = "filt1_key_track",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x35,
                    },
                    Parameter {
                       name = "Vel. sens.",
                       id = "filt1_vel_sens",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x36,
                    },
                    Parameter {
                       name = "Routing",
                       id = "routing",
                       items = {"single", "serial", "parallel", "indiv"},
                       item_values = range(0, 3),
                       number = 0x30,
                    },
                 },
                 Group {
                    name = "Filter 2",
                    Parameter {
                       name = "Cutoff",
                       id = "filt2_cutoff",
                       max_value = 127,
                       number = 0x42,
                    },
                    Parameter {
                       name = "Resonance",
                       id = "filt2_reso",
                       max_value = 127,
                       number = 0x43,
                    },
                    Parameter {
                       name = "Type",
                       id = "filt2_type",
                       items = {"LPF", "HPF", "BPF"},
                       item_values = range(0, 3),
                       number = 0x40,
                    },
                    Parameter {
                       name = "EG1 int",
                       id = "filt2_eg1_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x44,
                    },
                    Parameter {
                       name = "Key track",
                       id = "filt2_key_track",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x45,
                    },
                    Parameter {
                       name = "Vel sens",
                       id = "filt2_vel_sens",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x46,
                    },
                 },
                 Group {
                    name = "Amp",
                    Parameter {
                       name = "Level",
                       id = "level",
                       max_value = 127,
                       default_value = 127,
                       number = 0x50,
                    },
                    Parameter {
                       name = "Pan pot",
                       id = "panpot",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       value_callback = function (p)
                          return p.value + 64
                       end,
                       rev_value_callback = function (v)
                          return v - 64
                       end,
                       number = 0x55,
                    },
                    Parameter {
                       name = "Key track",
                       id = "key_track",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x56,
                    },
                 },
                 Group {
                    name = "EQ",
                    sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x09 + timbre*0x10, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
                    Parameter {
                       name = "Low freq",
                       id = "eq_low_freq",
                       max_value = 0x21,
                       number = 0x00,
                    },
                    Parameter {
                       name = "Low gain",
                       id = "eq_low_gain",
                       min_value = -30,
                       max_value = 30,
                       default_value = 0,
                       number = 0x01,
                    },
                    Parameter {
                       name = "High freq",
                       id = "eq_high_freq",
                       max_value = 0x19,
                       number = 0x02,
                    },
                    Parameter {
                       name = "High gain",
                       id = "eq_high_gain",
                       min_value = -30,
                       max_value = 30,
                       default_value = 0,
                       number = 0x03,
                    },
                 },
                 Group {
                    name = "EG1",
                    Parameter {
                       name = "Attack",
                       id = "eg1_attack",
                       max_value = 127,
                       number = 0x60,
                    },
                    Parameter {
                       name = "Decay",
                       id = "eg1_decay",
                       max_value = 127,
                       default_value = 127,
                       number = 0x61,
                    },
                    Parameter {
                       name = "Sustain",
                       id = "eg1_sustain",
                       max_value = 127,
                       number = 0x62,
                    },
                    Parameter {
                       name = "Release",
                       id = "eg1_release",
                       max_value = 127,
                       number = 0x63,
                    },
                    Parameter {
                       name = "Vel int",
                       id = "eg1_vel_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x64,
                    },
                 },
                 Group {
                    name = "EG2",
                    Parameter {
                       name = "Attack",
                       id = "eg2_attack",
                       max_value = 127,
                       number = 0x70,
                    },
                    Parameter {
                       name = "Decay",
                       id = "eg2_decay",
                       max_value = 127,
                       default_value = 127,
                       number = 0x71,
                    },
                    Parameter {
                       name = "Sustain",
                       id = "eg2_sustain",
                       max_value = 127,
                       number = 0x72,
                    },
                    Parameter {
                       name = "Release",
                       id = "eg2_release",
                       max_value = 127,
                       number = 0x73,
                    },
                    Parameter {
                       name = "Vel int",
                       id = "eg2_vel_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x74,
                    },
                 },
                 Group {
                    name = "EG3",
                    Parameter {
                       name = "Attack",
                       id = "eg3_attack",
                       max_value = 127,
                       number = 0x80,
                    },
                    Parameter {
                       name = "Decay",
                       id = "eg3_decay",
                       max_value = 127,
                       default_value = 127,
                       number = 0x81,
                    },
                    Parameter {
                       name = "Sustain",
                       id = "eg3_sustain",
                       max_value = 127,
                       number = 0x82,
                    },
                    Parameter {
                       name = "Release",
                       id = "eg3_release",
                       max_value = 127,
                       number = 0x83,
                    },
                    Parameter {
                       name = "Vel int",
                       id = "eg3_vel_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x84,
                    },
                 },
              },
              Section {
                 name = ("Timbre %d patches"):format(timbre),
                 sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x02 + timbre*0x10, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
                 Group {
                    name = "LFO1",
                    Parameter {
                       name = "Wave",
                       id = "lfo1_wave",
                       items = {"saw", "square", "triangle", "s&h", "random"},
                       item_values = range(0, 4),
                       number = 0x90,
                    },
                    Parameter {
                       name = "Key sync",
                       id = "lfo1_key_sync",
                       items = {"off", "timbre", "voice"},
                       item_values = range(0, 2),
                       number = 0x94,
                    },
                    Parameter {
                       name = "BPM sync",
                       id = "lfo1_bpm_sync",
                       items = {"off", "on"},
                       item_values = range(0, 2),
                       number = 0x93,
                    },
                    Parameter {
                       name = "Freq",
                       id = "lfo1_sync_freq",
                       max_value = 127,
                       number = 0x92,
                       notify_visibility = {"lfo1_bpm_sync"},
                       visibility = function (p)
                          return p.value == 1
                       end
                    },
                    Parameter {
                       name = "Sync note",
                       id = "lfo1_sync_note",
                       items = sync_notes,
                       item_values = range(0, (#sync_notes)-1),
                       number = 0x96,
                       notify_visibility = {"lfo1_bpm_sync"},
                       visibility = function (p)
                          return p.value == 2
                       end
                    },
                 },
                 Group {
                    name = "LFO2",
                    Parameter {
                       name = "Wave",
                       id = "lfo2_wave",
                       items = {"saw", "square+", "sine", "s&h", "random"},
                       item_values = range(0, 4),
                       number = 0xa0,
                    },
                    Parameter {
                       name = "Key sync",
                       id = "lfo2_key_sync",
                       items = {"off", "timbre", "voice"},
                       item_values = range(0, 2),
                       number = 0xa4,
                    },
                    Parameter {
                       name = "BPM sync",
                       id = "lfo2_bpm_sync",
                       items = {"off", "on"},
                       item_values = range(0, 2),
                       number = 0xa3,
                    },
                    Parameter {
                       name = "Freq",
                       id = "lfo2_sync_freq",
                       max_value = 127,
                       number = 0xa2,
                       notify_visibility = {"lfo2_bpm_sync"},
                       visibility = function (p)
                          return p.value == 1
                       end
                    },
                    Parameter {
                       name = "Sync note",
                       id = "lfo2_sync_note",
                       items = sync_notes,
                       item_values = range(0, (#sync_notes)-1),
                       number = 0xa6,
                       notify_visibility = {"lfo2_bpm_sync"},
                       visibility = function (p)
                          return p.value == 2
                       end
                    },
                 },
                 Group {
                    name = "Patch 1",
                    Parameter {
                       name = "Source",
                       id = "patch1_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x00,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch1_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x01,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch1_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x02,
                    },
                 },
                 Group {
                    name = "Patch 2",
                    Parameter {
                       name = "Source",
                       id = "patch2_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x04,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch2_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x05,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch2_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x06,
                    },
                 },
                 Group {
                    name = "Patch 3",
                    Parameter {
                       name = "Source",
                       id = "patch3_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x08,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch3_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x09,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch3_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x0a,
                    },
                 },
                 Group {
                    name = "Patch 4",
                    Parameter {
                       name = "Source",
                       id = "patch4_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x0c,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch4_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x0d,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch4_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x0e,
                    },
                 },
                 Group {
                    name = "Patch 5",
                    Parameter {
                       name = "Source",
                       id = "patch5_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x10,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch5_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x11,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch5_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x12,
                    },
                 },
                 Group {
                    name = "Patch 6",
                    Parameter {
                       name = "Source",
                       id = "patch6_source",
                       items = patch_sources,
                       item_values = range(0, (#patch_sources)-1),
                       number = 0x40,
                    },
                    Parameter {
                       name = "Destination",
                       id = "patch6_dest",
                       items = patch_dests,
                       item_values = range(0, (#patch_dests)-1),
                       number = 0x41,
                    },
                    Parameter {
                       name = "Intensity",
                       id = "patch6_int",
                       max_value = 63,
                       min_value = -63,
                       default_value = 0,
                       number = 0x42,
                    },
                 },
              },
   }

   return unpack(r)
end

local timbre_data_map = {
   [0x15] = "unisson_mode",
   [0x16] = "unisson_detune",
   [0x17] = "unisson_spread",
   [0x18] = function (value)
      return {{"assign_voice", math.floor(value/0x40)}}
   end,
   [0x1a] = "analog_tune",
   [0x1b] = function (value)
      return {{"transpose", value - 0x40}}
   end,
   [0x1c] = function (value)
      return {{"detune", value - 0x40}}
   end,
   [0x1d] = function (value)
      return {{"vib_int", value - 0x40}}
   end,
   [0x1e] = function (value)
      return {{"p_bend", value - 0x40}}
   end,
   [0x1f] = "portamento",
   [0x21] = function (value)
      return {{"wave_1", value%0x10},
              {"osc_mod_1", math.floor(value/0x10)}}
   end,
   [0x22] = function (value)
      return {{"osc1_mod_depth", value},
              {"osc1_detune", value},
              {"osc1_reso", value},
              {"osc1_waveform", value},
              {"osc1_wave_shape", value},
              {"osc1_formant_width", value},
              {"osc1_pulse_width", value},
              {"osc1_gain", value - 0x40}}
   end,
   [0x23] = function (value)
      return {{"osc1_harmonic", value},
              {"osc1_phase", value},
              {"osc1_bal", value - 0x40},
              {"osc1_formant_sft", value - 0x40},
              {"osc1_lfo1_mod_depth", value}}
   end,
   [0x24] = "osc1_sample",
   [0x26] = function (value)
      return {{"wave_2", value%0x10},
              {"osc_mod_2", math.floor(value/0x10)}}
   end,
   [0x27] = function (value)
      return {{"osc2_semi", value - 0x40}}
   end,
   [0x28] = function (value)
      return {{"osc2_tune", value - 0x40}}
   end,
   [0x29] = "osc1_lvl",
   [0x2a] = "osc2_lvl",
   [0x2b] = "noise_lvl",
   [0x2d] = function (value)
      return {{"routing", value%0x10},
              {"filt2_type", math.floor(value/0x10)}}
   end,
   [0x2e] = "filt1_type",
   [0x2f] = "filt1_cutoff",
   [0x30] = "filt1_reso",
   [0x31] = function (value)
      return {{"filt1_eg1_int", value - 0x40}}
   end,
   [0x32] = function (value)
      return {{"filt1_key_track", value - 0x40}}
   end,
   [0x33] = function (value)
      return {{"filt1_vel_sens", value - 0x40}}
   end,
   [0x34] = "filt2_cutoff",
   [0x35] = "filt2_reso",
   [0x36] = function (value)
      return {{"filt2_eg1_int", value - 0x40}}
   end,
   [0x37] = function (value)
      return {{"filt2_key_track", value - 0x40}}
   end,
   [0x38] = function (value)
      return {{"filt2_vel_sens", value - 0x40}}
   end,
   [0x39] = "level",
   [0x3a] = function (value)
      return {{"drive_position", math.floor(value/0x10)}}
   end,
   [0x3b] = "drive_type",
   [0x3c] = "drive_depth",
   [0x3d] = function (value)
      return {{"panpot", value - 64}}
   end,
   [0x3e] = function (value)
      return {{"key_track", value - 0x40}}
   end,
   [0x3f] = "punch_lvl",

   [0x41] = "eg1_attack",
   [0x42] = "eg1_decay",
   [0x43] = "eg1_sustain",
   [0x44] = "eg1_release",
   [0x45] = function (value)
      return {{"eg1_vel_int", value - 0x40}}
   end,

   [0x47] = "eg2_attack",
   [0x48] = "eg2_decay",
   [0x49] = "eg2_sustain",
   [0x4a] = "eg2_release",
   [0x4b] = function (value)
      return {{"eg2_vel_int", value - 0x40}}
   end,

   [0x4d] = "eg3_attack",
   [0x4e] = "eg3_decay",
   [0x4f] = "eg3_sustain",
   [0x50] = "eg3_release",
   [0x51] = function (value)
      return {{"eg3_vel_int", value - 0x40}}
   end,
   [0x53] = "lfo1_wave",
   [0x54] = "lfo1_sync_freq",
   [0x55] = function (value)
      return {{"lfo1_key_sync", math.floor(value/0x20)%4},
              {"lfo1_bpm_sync", math.floor(value/0x80)}}
   end,
   [0x56] = "lfo1_sync_note",               
   [0x57] = "lfo2_wave",
   [0x58] = "lfo2_sync_freq",
   [0x59] = function (value)
      return {{"lfo2_key_sync", math.floor(value/0x20)%4},
              {"lfo2_bpm_sync", math.floor(value/0x80)}}
   end,
   [0x5a] = "lfo2_sync_note",
   [0x5b] = "patch1_source",
   [0x5c] = "patch1_dest",
   [0x5d] = function (value)
      return {{"patch1_int", value - 0x40}}
   end,
   [0x5e] = "patch2_source",
   [0x5f] = "patch2_dest",
   [0x60] = function (value)
      return {{"patch2_int", value - 0x40}}
   end,
   [0x61] = "patch3_source",
   [0x62] = "patch3_dest",
   [0x63] = function (value)
      return {{"patch3_int", value - 0x40}}
   end,
   [0x64] = "patch4_source",
   [0x65] = "patch4_dest",
   [0x66] = function (value)
      return {{"patch4_int", value - 0x40}}
   end,
   [0x67] = "patch5_source",
   [0x68] = "patch5_dest",
   [0x69] = function (value)
      return {{"patch5_int", value - 0x40}}
   end,
   [0x6a] = "patch6_source",
   [0x6b] = "patch6_dest",
   [0x6c] = function (value)
      return {{"patch6_int", value - 0x40}}
   end,
   [0x6d] = "eq_low_freq",
   [0x6e] = function (value)
      return {{"eq_low_gain", value - 0x40}}
   end,
   [0x6f] = "eq_high_freq",
   [0x70] = function (value)
      return {{"eq_high_gain", value - 0x40}}
   end,
}

function get_timbre_data_map(timbre)
   local ret = {}
   local suffix = ("_%d"):format(timbre)
   for k, v in pairs(timbre_data_map) do
      if type(v) == "string" then
         ret[k + (timbre-1)*0x60] = v .. suffix
      else
         ret[k + (timbre-1)*0x60] = function (value)
            local r = v(value)
            for i, w in ipairs(r) do
               w[1] = w[1] .. suffix
            end
            return r
         end
      end
   end
   return ret
end

function merge_tables(...)
   local ret = {}
   for i, t in ipairs({...}) do
      for k, v in pairs(t) do
         ret[k] = v
      end
   end
   return ret
end

function MKSection(tbl)
end



local function get_fx_group(fx)
   local old_Parameter = Parameter
   local function Parameter(tbl)
      tbl.id = tbl.id .. ("_fx%d"):format(fx)
      tbl.number = tbl.number + (fx-1)*0x30

      if tbl.fx_type ~= nil then
         if tbl.notify_visibility == nil then
            tbl.notify_visibility = {}
         end
         table.insert(tbl.notify_visibility, "type")
         local old_visibility = tbl.visibility
         tbl.visibility = function (...)
            if old_visibility ~= nil and not old_visibility(...) then
               return false
            end
            local p = select(-1, ...)
            for i, v in ipairs(p.items) do
               if tbl.fx_type == v then
                  return p.value == i
               end
            end
            print(("Missing value '%s'\n"):format(tbl.fx_type))
         end
      end

      local p = old_Parameter(tbl)

      if tbl.notify_visibility ~= nil then
         for i, v in ipairs(tbl.notify_visibility) do
            tbl.notify_visibility[i] = ("%s_fx%d"):format(v, fx)
         end
      end

      return p
   end

   local r = Group {
      name = ("FX%d"):format(fx),
      Parameter {
         name = "Type",
         id = "type",
         items = fx_types,
         item_values = range(0, (#fx_types)-1),
         number = 0x01,
      },
      Parameter {
         name = "Dry/Wet",
         id = "dry_wet",
         max_value = 0x64,
         number = 0x10,
         notify_visibility = {"type"},
         visibility = function (p)
            return p.value ~= 1
         end
      },

      Parameter {
         fx_type = "compressor",
         name = "Ctrl 1",
         id = "comp_ctrl_1",
         items = {"sens", "attack"},
         item_values = {2, 3},
         number = 0x02,
      },
      Parameter {
         fx_type = "compressor",
         name = "Ctrl 2",
         id = "comp_ctrl_2",
         items = {"sens", "attack"},
         item_values = {2, 3},
         number = 0x03,
      },
      Parameter {
         fx_type = "compressor",
         name = "Env sel",
         id = "comp_env_sel",
         items = {"LR mix", "LR indiv"},
         item_values = {0, 1},
         number = 0x11,
      },
      Parameter {
         fx_type = "compressor",
         name = "Sens",
         id = "comp_sens",
         min_value = 1,
         max_value = 127,
         default_value = 1,
         number = 0x12,
      },
      Parameter {
         fx_type = "compressor",
         name = "Attack",
         id = "comp_attack",
         number = 0x13,
         max_value = 127,
      },
      Parameter {
         fx_type = "compressor",
         name = "Out level",
         id = "comp_out_level",            
         number = 0x14,
         max_value = 127,
      },
      
      Parameter {
         fx_type = "filter",
         name = "Ctrl 1",
         id = "filter_ctrl_1",
         items = {"cutoff", "reso", "mod int", "response", "lfo freq", "sync note"},
         item_values = {2, 3, 6, 7, 9, 10},
         number = 0x02,
      },
      Parameter {
         fx_type = "filter",
         name = "Ctrl 2",
         id = "filter_ctrl_2",
         items = {"cutoff", "reso", "mod int", "response", "lfo freq", "sync note"},
         item_values = {2, 3, 6, 7, 9, 10},
         number = 0x03,
      },
      Parameter {
         fx_type = "filter",
         name = "Type",
         id = "filter_type",
         items = {"LPF24", "LPF18", "LPF12", "HPF12", "BPF12"},
         item_values = range(0, 4),
         number = 0x11,
      },
      Parameter {
         fx_type = "filter",
         name = "Cutoff",
         id = "filter_cutoff",
         max_value = 127,
         number = 0x12,
      },
      Parameter {
         fx_type = "filter",
         name = "Attack",
         id = "filter_reso",
         number = 0x13,
         max_value = 127,
      },
      Parameter {
         fx_type = "filter",
         name = "Trim",
         id = "filter_trim",
         number = 0x14,
         max_value = 127,
      },
      Parameter {
         fx_type = "filter",
         name = "Mod src",
         id = "filter_mod_src",
         number = 0x15,
         items = {"LFO", "ctrl"},
         item_values = {0, 1},
      },
      Parameter {
         fx_type = "filter",
         name = "Mod int",
         id = "filter_mod_int",
         number = 0x16,
         min_value = -63,
         max_value = 63,
         default_value = 0,
      },
      Parameter {
         fx_type = "filter",
         name = "Response",
         id = "filter_resp",
         number = 0x17,
         max_value = 127,
      },
      Parameter {
         fx_type = "filter",
         name = "LFO sync",
         id = "filter_lfo_sync",
         number = 0x18,
         items = {"OFF", "ON"},
         item_values = {0, 1},
      },
      Parameter {
         fx_type = "filter",
         name = "LFO freq",
         id = "filter_lfo_freq",
         number = 0x19,
         max_value = 127,
         notify_visibility = {"filter_lfo_sync"},
         visibility = function (lfo_sync)
            return lfo_sync.value == 1
         end
      },
      Parameter {
         fx_type = "filter",
         name = "Sync note",
         id = "filter_lfo_sync_note",
         number = 0x1a,
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         notify_visibility = {"filter_lfo_sync"},
         visibility = function (lfo_sync)
            return lfo_sync.value == 2
         end
      },
      Parameter {
         fx_type = "filter",
         name = "LFO wave",
         id = "filter_lfo_wave",
         number = 0x1b,
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
      },
      Parameter {
         fx_type = "filter",
         name = "LFO shape",
         id = "filter_lfo_shape",
         number = 0x1c,
         min_value = -63,
         max_value = 63,
         default_value = 0,
      },
      Parameter {
         fx_type = "filter",
         name = "Key sync",
         id = "filter_key_sync",
         number = 0x1d,
         items = {"OFF", "ON"},
         item_values = {0, 1},
      },
      Parameter {
         fx_type = "filter",
         name = "Ini phase",
         id = "filter_ini_phase",
         number = 0x1e,
         max_value = 18,
         notify_visibility = {"filter_key_sync"},
         visibility = function (key_sync)
            return key_sync.value == 2
         end
      },

      Parameter {
         fx_type = "band eq",
         name = "Ctrl 1",
         id = "bandeq_ctrl_1",
         items = {"B1 gain", "B2 gain", "B3 gain", "B4 gain"},
         item_values = {0x5, 0x8, 0xb, 0xf},
         number = 0x02,
      },
      Parameter {
         fx_type = "band eq",
         name = "Ctrl 2",
         id = "bandeq_ctrl_2",
         items = {"B1 gain", "B2 gain", "B3 gain", "B4 gain"},
         item_values = {0x5, 0x8, 0xb, 0xf},
         number = 0x03,
      },
      Parameter {
         fx_type = "band eq",
         name = "Trim",
         id = "bandeq_trim",
         max_Value = 127,
         number = 0x11,
      },
      Parameter {
         fx_type = "band eq",
         name = "B1 type",
         id = "bandeq_b1_type",
         items = {"peaking", "shelv lo"},
         item_values = {0, 1},
         number = 0x12,
      },
      Parameter {
         fx_type = "band eq",
         name = "B1 freq",
         id = "bandeq_b1_freq",
         number = 0x13,
         max_value = 0x3a,
      },
      Parameter {
         fx_type = "band eq",
         name = "B1 Q",
         id = "bandeq_b1_q",
         number = 0x14,
         max_value = 0x5f,
         notify_visibility = {"bandeq_b1_type"},
         visibility = function (t)
            return t.value == 1
         end
      },
      Parameter {
         fx_type = "band eq",
         name = "B1 gain",
         id = "bandeq_b1_gain",
         number = 0x15,
         min_value = -36,
         max_value = 36,
         default_value = 0,
      },

      Parameter {
         fx_type = "band eq",
         name = "B2 freq",
         id = "bandeq_b2_freq",
         number = 0x16,
         max_value = 0x3a,
      },
      Parameter {
         fx_type = "band eq",
         name = "B2 Q",
         id = "bandeq_b2_q",
         number = 0x17,
         max_value = 0x5f,
      },
      Parameter {
         fx_type = "band eq",
         name = "B2 gain",
         id = "bandeq_b2_gain",
         number = 0x18,
         min_value = -36,
         max_value = 36,
         default_value = 0,
      },

      Parameter {
         fx_type = "band eq",
         name = "B3 freq",
         id = "bandeq_b3_freq",
         number = 0x19,
         max_value = 0x3a,
      },
      Parameter {
         fx_type = "band eq",
         name = "B3 Q",
         id = "bandeq_b3_q",
         number = 0x1a,
         max_value = 0x5f,
      },
      Parameter {
         fx_type = "band eq",
         name = "B3 gain",
         id = "bandeq_b3_gain",
         number = 0x1b,
         min_value = -36,
         max_value = 36,
         default_value = 0,
      },

      Parameter {
         fx_type = "band eq",
         name = "B4 type",
         id = "bandeq_b4_type",
         items = {"peaking", "shelv lo"},
         item_values = {0, 1},
         number = 0x1c,
      },
      Parameter {
         fx_type = "band eq",
         name = "B4 freq",
         id = "bandeq_b4_freq",
         number = 0x1d,
         max_value = 0x3a,
      },
      Parameter {
         fx_type = "band eq",
         name = "B4 Q",
         id = "bandeq_b4_q",
         number = 0x1e,
         max_value = 0x5f,
         notify_visibility = {"bandeq_b4_type"},
         visibility = function (t)
            return t.value == 1
         end
      },
      Parameter {
         fx_type = "band eq",
         name = "B4 gain",
         id = "bandeq_b4_gain",
         number = 0x1f,
         min_value = -36,
         max_value = 36,
         default_value = 0,
      },

      Parameter {
         fx_type = "distortion",
         name = "Ctrl 1",
         id = "distortion_ctrl_1",
         items = {"gain", "pre gain",
                  "B1 gain", "B2 gain", "B3 gain"},
         item_values = {0x1, 0x4, 0x7, 0xa, 0xd},
         number = 0x02,
      },
      Parameter {
         fx_type = "distortion",
         name = "Ctrl 2",
         id = "distortion_ctrl_2",
         items = {"gain", "pre gain",
                  "B1 gain", "B2 gain", "B3 gain"},
         item_values = {0x1, 0x4, 0x7, 0xa, 0xd},
         number = 0x03,
      },

      Parameter {
         fx_type = "distortion",
         name = "Gain",
         id = "distortion_gain",
         max_value = 127,
         number = 0x11,
      },

      Parameter {
         fx_type = "distortion",
         name = "Pre freq",
         id = "distortion_pre_freq",
         max_value = 0x3a,
         number = 0x12,
      },

      Parameter {
         fx_type = "distortion",
         name = "Pre Q",
         id = "distortion_pre_q",
         max_value = 0x5f,
         number = 0x13,
      },

      Parameter {
         fx_type = "distortion",
         name = "Pre gain",
         id = "distortion_pre_gain",
         max_value = 36,
         min_value = -36,
         default_value = 0,
         number = 0x14,
      },

      Parameter {
         fx_type = "distortion",
         name = "B1 freq",
         id = "distortion_b1_freq",
         max_value = 0x3a,
         number = 0x15,
      },
      
      Parameter {
         fx_type = "distortion",
         name = "B1 Q",
         id = "distortion_b1_q",
         max_value = 0x5f,
         number = 0x16,
      },

      Parameter {
         fx_type = "distortion",
         name = "B1 gain",
         id = "distortion_b1_gain",
         max_value = 36,
         min_value = -36,
         default_value = 0,
         number = 0x17,
      },

      Parameter {
         fx_type = "distortion",
         name = "B2 freq",
         id = "distortion_b2_freq",
         max_value = 0x3a,
         number = 0x18,
      },
      
      Parameter {
         fx_type = "distortion",
         name = "B2 Q",
         id = "distortion_b2_q",
         max_value = 0x5f,
         number = 0x19,
      },

      Parameter {
         fx_type = "distortion",
         name = "B2 gain",
         id = "distortion_b2_gain",
         max_value = 36,
         min_value = -36,
         default_value = 0,
         number = 0x1a,
      },

      Parameter {
         fx_type = "distortion",
         name = "B3 freq",
         id = "distortion_b3_freq",
         max_value = 0x3a,
         number = 0x1b,
      },
      
      Parameter {
         fx_type = "distortion",
         name = "B3 Q",
         id = "distortion_b3_q",
         max_value = 0x5f,
         number = 0x1c,
      },

      Parameter {
         fx_type = "distortion",
         name = "B3 gain",
         id = "distortion_b3_gain",
         max_value = 36,
         min_value = -36,
         default_value = 0,
         number = 0x1d,
      },

      Parameter {
         fx_type = "distortion",
         name = "Out level",
         id = "distortion_out_level",
         max_value = 127,
         number = 0x1e,
      },

      Parameter {
         fx_type = "decimator",
         name = "Ctrl 1",
         id = "decimator_ctrl_1",
         items = {"FS", "bit", "FS mod int", "LFO freq"},
         item_values = {0x3, 0x4, 0x6, 0x8},
         number = 0x02,
      },

      Parameter {
         fx_type = "decimator",
         name = "Ctrl 2",
         id = "decimator_ctrl_2",
         items = {"FS", "bit", "FS mod int", "LFO freq"},
         item_values = {0x3, 0x4, 0x6, 0x8},
         number = 0x03,
      },

      Parameter {
         fx_type = "decimator",
         name = "Pre LPF",
         id = "decimator_pre_lpf",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },


      Parameter {
         fx_type = "decimator",
         name = "Hi damp",
         id = "decimator_hi_damp",
         max_value = 0x64,
         number = 0x12,
      },

      Parameter {
         fx_type = "decimator",
         name = "FS",
         id = "decimator_fs",
         max_value = 0x5e,
         number = 0x13,
      },

      Parameter {
         fx_type = "decimator",
         name = "Bit",
         id = "decimator_bit",
         max_value = 20,
         number = 0x14,
      },

      Parameter {
         fx_type = "decimator",
         name = "Out level",
         id = "decimator_out_level",
         max_value = 127,
         number = 0x15,
      },


      Parameter {
         fx_type = "decimator",
         name = "FS mod int",
         id = "decimator_fs_mod_int",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x16,
      },

      Parameter {
         fx_type = "decimator",
         name = "LFO sync",
         id = "decimator_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x17,
      },

      Parameter {
         fx_type = "decimator",
         name = "LFO freq",
         id = "decimator_lfo_freq",
         max_value = 127,
         number = 0x18,
         notify_visibility = {"decimator_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "decimator",
         name = "Sync note",
         id = "decimator_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x19,
         notify_visibility = {"decimator_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },
      
      Parameter {
         fx_type = "decimator",
         name = "LFO wave",
         id = "decimator_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x1a,
      },
      
      Parameter {
         fx_type = "decimator",
         name = "LFO shape",
         id = "decimator_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x1b,
      },


      Parameter {
         fx_type = "decimator",
         name = "Key sync",
         id = "decimator_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1c,
      },

      Parameter {
         fx_type = "decimator",
         name = "Ini phase",
         id = "decimator_ini_phase",
         max_value = 0x1e,
         number = 0x1d,
         notify_visibility = {"decimator_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "delay",
         name = "Ctrl 1",
         id = "delay_ctrl_1",
         items = {"TM ratio", "TM ratio (sync)", "feedback"},
         item_values = {0x3, 0x6, 0x9},
         number = 0x02,
      },

      Parameter {
         fx_type = "delay",
         name = "Ctrl 2",
         id = "delay_ctrl_2",
         items = {"TM ratio", "TM ratio (sync)", "feedback"},
         item_values = {0x3, 0x6, 0x9},
         number = 0x3,
      },

      Parameter {
         fx_type = "delay",
         name = "Type",
         id = "delay_type",
         items = {"stereo", "cross"},
         item_values = {0, 1},
         number = 0x11,
      },

       Parameter {
         fx_type = "delay",
         name = "BPM sync",
         id = "delay_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x12,
      },
      
      Parameter {
         fx_type = "delay",
         name = "TM ratio",
         id = "delay_tm_ratio",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "delay",
         name = "L delay",
         id = "delay_l_delay",
         max_value = 127,
         number = 0x14,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },
      Parameter {
         fx_type = "delay",
         name = "R delay",
         id = "delay_r_delay",
         max_value = 127,
         number = 0x15,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "delay",
         name = "TM ratio (sync)",
         id = "delay_tm_ratio_sync",
         max_value = 0xe,
         number = 0x16,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "delay",
         name = "L delay (sync)",
         id = "delay_l_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "delay",
         name = "R delay (sync)",
         id = "delay_r_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x18,
         notify_visibility = {"delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "delay",
         name = "Feedback",
         id = "delay_feedback",
         max_value = 127,
         number = 0x19,
      },

      Parameter {
         fx_type = "delay",
         name = "Hi damp",
         id = "delay_hi_damp",
         max_value = 0x64,
         number = 0x1a,
      },

      Parameter {
         fx_type = "delay",
         name = "Trim",
         id = "delay_trim",
         max_value = 127,
         number = 0x1b,
      },

      Parameter {
         fx_type = "delay",
         name = "Spread",
         id = "delay_spread",
         max_value = 127,
         number = 0x1c,
      },
      
      Parameter {
         fx_type = "lcr delay",
         name = "Ctrl 1",
         id = "lcr_delay_ctrl_1",
         items = {"TM ratio", "TM ratio (sync)", "C feedback"},
         item_values = {0x2, 0x6, 0xd},
         number = 0x02,
      },
      Parameter {
         fx_type = "lcr delay",
         name = "Ctrl 2",
         id = "lcr_delay_ctrl_2",
         items = {"TM ratio", "TM ratio (sync)", "C feedback"},
         item_values = {0x2, 0x6, 0xd},
         number = 0x03,
      },

      Parameter {
         fx_type = "lcr delay",
         name = "BPM sync",
         id = "lcr_delay_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "lcr delay",
         name = "TM ratio",
         id = "lcr_delay_tm_ratio",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "L delay",
         id = "lcr_delay_l_delay",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "C delay",
         id = "lcr_delay_c_delay",
         max_value = 127,
         number = 0x14,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "R delay",
         id = "lcr_delay_r_delay",
         max_value = 127,
         number = 0x15,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "TM ratio (sync)",
         id = "lcr_delay_tm_ratio_sync",
         max_value = 0xe,
         number = 0x16,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "L delay (sync)",
         id = "lcr_delay_l_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "C delay (sync)",
         id = "lcr_delay_c_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x18,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "R delay (sync)",
         id = "lcr_delay_r_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x19,
         notify_visibility = {"lcr_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "lcr delay",
         name = "L level",
         id = "lcr_delay_l_level",
         max_value = 127,
         number = 0x1a,
      },
      Parameter {
         fx_type = "lcr delay",
         name = "C level",
         id = "lcr_delay_c_level",
         max_value = 127,
         number = 0x1b,
      },
      Parameter {
         fx_type = "lcr delay",
         name = "R level",
         id = "lcr_delay_r_level",
         max_value = 127,
         number = 0x1c,
      },

      Parameter {
         fx_type = "lcr delay",
         name = "C feedback",
         id = "lcr_delay_c_feedback",
         max_value = 127,
         number = 0x1d,
      },

      Parameter {
         fx_type = "lcr delay",
         name = "Trim",
         id = "lcr_delay_trim",
         max_value = 127,
         number = 0x1e,
      },

      Parameter {
         fx_type = "lcr delay",
         name = "Spread",
         id = "lcr_delay_spread",
         max_value = 127,
         number = 0x1f,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Ctrl 1",
         id = "pan_delay_ctrl_1",
         items = {"TM ratio", "TM ratio (sync)", "feedback", "mod depth", "lfo freq"},
         item_values = {0x2, 0x5, 0x9, 0xb},
         number = 0x02,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Ctrl 2",
         id = "pan_delay_ctrl_2",
         items = {"TM ratio", "TM ratio (sync)", "feedback", "mod depth", "lfo freq"},
         item_values = {0x2, 0x5, 0x9, 0xb},
         number = 0x03,
      },

      Parameter {
         fx_type = "pan delay",
         name = "BPM sync",
         id = "pan_delay_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "pan delay",
         name = "TM ratio",
         id = "pan_delay_tm_ratio",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "L delay",
         id = "pan_delay_l_delay",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "R delay",
         id = "pan_delay_r_delay",
         max_value = 127,
         number = 0x14,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "TM ratio (sync)",
         id = "pan_delay_tm_ratio_sync",
         max_value = 0xe,
         number = 0x15,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "L delay (sync)",
         id = "pan_delay_l_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x16,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "R delay (sync)",
         id = "pan_delay_r_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"pan_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "Feedback",
         id = "pan_delay_feedback",
         max_value = 127,
         number = 0x18,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Mod depth",
         id = "pan_delay_mod_depth",
         max_value = 127,
         number = 0x19,
      },

      Parameter {
         fx_type = "pan delay",
         name = "LFO sync",
         id = "pan_delay_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1a,
      },

      Parameter {
         fx_type = "pan delay",
         name = "LFO freq",
         id = "pan_delay_lfo_freq",
         max_value = 127,
         number = 0x1b,
         notify_visibility = {"pan_delay_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "Sync note",
         id = "pan_delay_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x1c,
         notify_visibility = {"pan_delay_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "LFO wave",
         id = "pan_delay_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x1d,
      },

      Parameter {
         fx_type = "pan delay",
         name = "LFO shape",
         id = "pan_delay_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x1e,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Key sync",
         id = "pan_delay_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1f,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Ini phase",
         id = "pan_delay_ini_phase",
         max_value = 0x12,
         number = 0x20,
         notify_visibility = {"pan_delay_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "pan delay",
         name = "LFO spread",
         id = "pan_delay_lfo_spread",
         max_value = 18,
         min_value = -18,
         default_value = 0,
         number = 0x21,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Hi damp",
         id = "pan_delay_hi_damp",
         max_value = 0x64,
         number = 0x22,
      },

      Parameter {
         fx_type = "pan delay",
         name = "Trim",
         id = "pan_delay_trim",
         max_value = 127,
         number = 0x23,
      },

      Parameter {
         fx_type = "mod delay",
         name = "Ctrl 1",
         id = "mod_delay_ctrl_1",
         items = {"TM ratio", "TM ration (sync)", "feedback", "mod depth", "lfo freq"},
         item_values = {0x2, 0x5, 0x8, 0x9, 0xa},
         number = 0x02,
      },

      Parameter {
         fx_type = "mod delay",
         name = "Ctrl 1",
         id = "mod_delay_ctrl_2",
         items = {"TM ratio", "TM ration (sync)", "feedback", "mod depth", "lfo freq"},
         item_values = {0x2, 0x5, 0x8, 0x9, 0xa},
         number = 0x03,
      },
  
      Parameter {
         fx_type = "mod delay",
         name = "BPM sync",
         id = "mod_delay_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "mod delay",
         name = "TM ratio",
         id = "mod_delay_tm_ratio",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "mod delay",
         name = "L delay",
         id = "mod_delay_l_delay",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },
      Parameter {
         fx_type = "mod delay",
         name = "R delay",
         id = "mod_delay_r_delay",
         max_value = 127,
         number = 0x14,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "mod delay",
         name = "TM ratio (sync)",
         id = "mod_delay_tm_ratio_sync",
         max_value = 0xe,
         number = 0x15,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "mod delay",
         name = "L delay (sync)",
         id = "mod_delay_l_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x16,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "mod delay",
         name = "R delay (sync)",
         id = "mod_delay_r_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"mod_delay_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "mod delay",
         name = "Feedback",
         id = "mod_delay_feedback",
         max_value = 127,
         number = 0x18,
      },

      Parameter {
         fx_type = "mod delay",
         name = "Mod depth",
         id = "mod_delay_mod_depth",
         max_value = 127,
         number = 0x19,
      },

      Parameter {
         fx_type = "mod delay",
         name = "LFO freq",
         id = "mod_delay_lfo_freq",
         max_value = 127,
         number = 0x1a,
      },


      Parameter {
         fx_type = "mod delay",
         name = "LFO spread",
         id = "mod_delay_lfo_spread",
         max_value = 18,
         min_value = -18,
         default_value = 0,
         number = 0x1b,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Ctrl 1",
         id = "tape_echo_ctrl_1",
         items = {"TM ratio", "TM ratio (sync)", "Tap1 lvl", "Tap2 lvl", "Feedback", "Saturation"},
         item_values = {0x2, 0x5, 0x8, 0x9, 0xa, 0xe},
         number = 0x02,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Ctrl 1",
         id = "tape_echo_ctrl_2",
         items = {"TM ratio", "TM ratio (sync)", "Tap1 lvl", "Tap2 lvl", "Feedback", "Saturation"},
         item_values = {0x2, 0x5, 0x8, 0x9, 0xa, 0xe},
         number = 0x03,
      },

      Parameter {
         fx_type = "tape echo",
         name = "BPM sync",
         id = "tape_echo_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "tape echo",
         name = "TM ratio",
         id = "tape_echo_tm_ratio",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "Tap1 delay",
         id = "tape_echo_1_delay",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "Tap2 delay",
         id = "tape_echo_2_delay",
         max_value = 127,
         number = 0x14,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "TM ratio (sync)",
         id = "tape_echo_tm_ratio_sync",
         max_value = 0xe,
         number = 0x15,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "Tap1 delay (sync)",
         id = "tape_echo_1_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x16,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "Tap2 delay (sync)",
         id = "tape_echo_2_delay_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"tape_echo_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "tape echo",
         name = "Tap1 lvl",
         id = "tape_echo_1_lvl",
         max_value = 127,
         number = 0x18,
      },
      Parameter {
         fx_type = "tape echo",
         name = "Tap2 lvl",
         id = "tape_echo_2_lvl",
         max_value = 127,
         number = 0x19,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Feedback",
         id = "tape_echo_feedback",
         max_value = 127,
         number = 0x1a,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Hi damp",
         id = "tape_echo_hi_damp",
         max_value = 0x64,
         number = 0x1b,
      },
      Parameter {
         fx_type = "tape echo",
         name = "Lo damp",
         id = "tape_echo_lo_damp",
         max_value = 0x64,
         number = 0x1c,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Trim",
         id = "tape_echo_trim",
         max_value = 127,
         number = 0x1d,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Saturation",
         id = "tape_echo_saturation",
         max_value = 127,
         number = 0x1e,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Wow freq",
         id = "tape_echo_wow_freq",
         max_value = 127,
         number = 0x1f,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Wow depth",
         id = "tape_echo_wow_depth",
         max_value = 127,
         number = 0x20,
      },
      
      Parameter {
         fx_type = "tape echo",
         name = "Pre tone",
         id = "tape_echo_pre_tone",
         max_value = 127,
         number = 0x21,
      },

      Parameter {
         fx_type = "tape echo",
         name = "Spread",
         id = "tape_echo_spread",
         max_value = 127,
         number = 0x22,
      },     

      Parameter {
         fx_type = "chorus",
         name = "Chorus",
         id = "chorus_ctrl_1",
         items = {"mod depth", "lfo freq"},
         item_values = {0x1, 0x2},
         number = 0x02,
      },
      Parameter {
         fx_type = "chorus",
         name = "Chorus",
         id = "chorus_ctrl_2",
         items = {"mod depth", "lfo freq"},
         item_values = {0x1, 0x2},
         number = 0x03,
      },

      Parameter {
         fx_type = "chorus",
         name = "Mod depth",
         id = "chorus_mod_depth",
         max_value = 127,
         number = 0x11,
      },      

      Parameter {
         fx_type = "chorus",
         name = "LFO freq",
         id = "chorus_lfo_freq",
         max_value = 127,
         number = 0x12,
      },      

      Parameter {
         fx_type = "chorus",
         name = "LFO spread",
         id = "chorus_lfo_spread",
         max_value = 18,
         min_value = -18,
         default_value = 0,
         number = 0x13,
      },      

      Parameter {
         fx_type = "chorus",
         name = "Pre delay L",
         id = "chorus_pre_delay_l",
         max_value = 0x77,
         number = 0x14,
      },      

      Parameter {
         fx_type = "chorus",
         name = "Pre delay R",
         id = "chorus_pre_delay_r",
         max_value = 0x77,
         number = 0x15,
      },      

      Parameter {
         fx_type = "chorus",
         name = "Trim",
         id = "chorus_trim",
         max_value = 127,
         number = 0x16,
      },      

      Parameter {
         fx_type = "chorus",
         name = "Hi eq gain",
         id = "chorus_hi_eq_gain",
         max_value = 30,
         min_value = -30,
         default_value = 0,
         number = 0x17,
      },      

      Parameter {
         fx_type = "flanger",
         name = "Ctrl 1",
         id = "flanger_ctrl_1",
         items = {"delay", "mod depth", "feedback", "lfo freq", "lfo_sync_note"},
         item_values = {0x1, 0x2, 0x3, 0x6},
         number = 0x02,
      },

      Parameter {
         fx_type = "flanger",
         name = "Ctrl 2",
         id = "flanger_ctrl_2",
         items = {"delay", "mod depth", "feedback", "lfo freq", "lfo_sync_note"},
         item_values = {0x1, 0x2, 0x3, 0x6},
         number = 0x03,
      },

      Parameter {
         fx_type = "flanger",
         name = "Delay",
         id = "flanger_delay",
         max_value = 0x71,
         number = 0x11,
      },
      
     Parameter {
         fx_type = "flanger",
         name = "Mod depth",
         id = "flanger_mod_depth",
         max_value = 127,
         number = 0x12,
      },

     Parameter {
         fx_type = "flanger",
         name = "Feedback",
         id = "flanger_feedback",
         max_value = 127,
         number = 0x13,
      },

     Parameter {
         fx_type = "flanger",
         name = "Phase",
         id = "flanger_phase",
         items = {"+", "-"},
         item_values = {0, 1},
         number = 0x14,
      },

     Parameter {
         fx_type = "flanger",
         name = "LFO sync",
         id = "flanger_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x15,
      },

      Parameter {
         fx_type = "flanger",
         name = "LFO freq",
         id = "flanger_lfo_freq",
         max_value = 127,
         number = 0x16,
         notify_visibility = {"flanger_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "flanger",
         name = "Sync note",
         id = "flanger_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x17,
         notify_visibility = {"flanger_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "flanger",
         name = "LFO wave",
         id = "flanger_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x18,
      },

      Parameter {
         fx_type = "flanger",
         name = "LFO shape",
         id = "flanger_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x19,
      },

      Parameter {
         fx_type = "flanger",
         name = "Key sync",
         id = "flanger_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1a,
      },

      Parameter {
         fx_type = "flanger",
         name = "Ini phase",
         id = "flanger_ini_phase",
         max_value = 0x12,
         number = 0x1b,
         notify_visibility = {"flanger_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "flanger",
         name = "LFO spread",
         id = "flanger_lfo_spread",
         min_value = -18,
         max_value = 18,
         default_value = 0,
         number = 0x1c,
      },

      Parameter {
         fx_type = "flanger",
         name = "Hi damp",
         id = "flanger_hi_damp",
         max_value = 0x64,
         number = 0x1d,
      },

      Parameter {
         fx_type = "vibrato",
         name = "Ctrl 1",
         id = "vibrato_ctrl_1",
         items = {"mod depth", "lfo freq", "sync note"},
         item_values = {0x1, 0x3, 0x4},
         number = 0x02,
      },

      Parameter {
         fx_type = "vibrato",
         name = "Ctrl 2",
         id = "vibrato_ctrl_2",
         items = {"mod depth", "lfo freq", "sync note"},
         item_values = {0x1, 0x3, 0x4},
         number = 0x03,
      },
      
      Parameter {
         fx_type = "vibrato",
         name = "Mod depth",
         id = "vibrato_mod_depth",
         max_value = 127,
         number = 0x11,
      },

      Parameter {
         fx_type = "vibrato",
         name = "LFO sync",
         id = "vibrato_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x12,
      },

      Parameter {
         fx_type = "vibrato",
         name = "LFO freq",
         id = "vibrato_lfo_freq",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"vibrato_lfo_sync"},
         visibility = function (p)
            return p.value == 1
         end
      },

      Parameter {
         fx_type = "vibrato",
         name = "Sync note",
         id = "vibrato_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x14,
         notify_visibility = {"vibrato_lfo_sync"},
         visibility = function (p)
            return p.value == 1
         end
      },

      Parameter {
         fx_type = "vibrato",
         name = "LFO wave",
         id = "vibrato_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x15,
      },

      Parameter {
         fx_type = "vibrato",
         name = "LFO shape",
         id = "vibrato_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x16,
      },

      Parameter {
         fx_type = "vibrato",
         name = "Key sync",
         id = "vibrato_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x17,
      },

      Parameter {
         fx_type = "vibrato",
         name = "Ini phase",
         id = "vibrato_ini_phase",
         max_value = 0x12,
         number = 0x18,
         notify_visibility = {"vibrato_key_sync"},
         visibility = function (p)
            return p.value == 2
         end
      },

      Parameter {
         fx_type = "vibrato",
         name = "LFO spread",
         id = "vibrato_lfo_spread",
         max_value = 18,
         min_value = -18,
         default_value = 0,
         number = 0x19,
      },
      
      Parameter {
         fx_type = "phaser",
         name = "Ctrl 1",
         id = "phaser_ctrl_1",
         items = {"manual", "mod depth", "reso", "lfo freq", "sync note"},
         item_values = {0x2, 0x3, 0x4, 0x7, 0x8},
         number = 0x02,
      },
      Parameter {
         fx_type = "phaser",
         name = "Ctrl 2",
         id = "phaser_ctrl_2",
         items = {"manual", "mod depth", "reso", "lfo freq", "sync note"},
         item_values = {0x2, 0x3, 0x4, 0x7, 0x8},
         number = 0x03,
      },

      Parameter {
         fx_type = "phaser",
         name = "Type",
         id = "phaser_type",
         items = {"blue", "u-vb"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "phaser",
         name = "Manual",
         id = "phaser_manual",
         max_value = 127,
         number = 0x12,
      },

      Parameter {
         fx_type = "phaser",
         name = "Mod depth",
         id = "phaser_mod_depth",
         max_value = 127,
         number = 0x13,
      },

      Parameter {
         fx_type = "phaser",
         name = "Reso",
         id = "phaser_reso",
         max_value = 127,
         number = 0x14,
      },
     
      Parameter {
         fx_type = "phaser",
         name = "Phase",
         id = "phaser_phase",
         items = {"+", "-"},
         item_values = {0, 1},
         number = 0x15,
      },

     Parameter {
         fx_type = "phaser",
         name = "LFO sync",
         id = "phaser_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x16,
      },

      Parameter {
         fx_type = "phaser",
         name = "LFO freq",
         id = "phaser_lfo_freq",
         max_value = 127,
         number = 0x17,
         notify_visibility = {"phaser_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "phaser",
         name = "Sync note",
         id = "phaser_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x18,
         notify_visibility = {"phaser_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "phaser",
         name = "LFO wave",
         id = "phaser_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x19,
      },

      Parameter {
         fx_type = "phaser",
         name = "LFO shape",
         id = "phaser_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x1a,
      },

      Parameter {
         fx_type = "phaser",
         name = "Key sync",
         id = "phaser_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1b,
      },

      Parameter {
         fx_type = "phaser",
         name = "Ini phase",
         id = "phaser_ini_phase",
         max_value = 0x12,
         number = 0x1c,
         notify_visibility = {"phaser_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "phaser",
         name = "LFO spread",
         id = "phaser_lfo_spread",
         min_value = -18,
         max_value = 18,
         default_value = 0,
         number = 0x1d,
      },

      Parameter {
         fx_type = "phaser",
         name = "Hi damp",
         id = "phaser_hi_damp",
         max_value = 0x64,
         number = 0x1e,
      },

      Parameter {
         fx_type = "tremolo",
         name = "Ctrl 1",
         id = "tremolo_ctrl_1",
         items = {"mod depth", "lfo freq", "sync note"},
         item_values = {0x1, 0x3, 0x4},
         number = 0x02,
      },
      Parameter {
         fx_type = "tremolo",
         name = "Ctrl 2",
         id = "tremolo_ctrl_2",
         items = {"mod depth", "lfo freq", "sync note"},
         item_values = {0x1, 0x3, 0x4},
         number = 0x03,
      },

      Parameter {
         fx_type = "tremolo",
         name = "Mod depth",
         id = "tremolo_mod_depth",
         max_value = 127,
         number = 0x11,
      },
      
     Parameter {
         fx_type = "tremolo",
         name = "LFO sync",
         id = "tremolo_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x12,
      },

      Parameter {
         fx_type = "tremolo",
         name = "LFO freq",
         id = "tremolo_lfo_freq",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"tremolo_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "tremolo",
         name = "Sync note",
         id = "tremolo_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x14,
         notify_visibility = {"tremolo_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "tremolo",
         name = "LFO wave",
         id = "tremolo_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x15,
      },

      Parameter {
         fx_type = "tremolo",
         name = "LFO shape",
         id = "tremolo_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x16,
      },

      Parameter {
         fx_type = "tremolo",
         name = "Key sync",
         id = "tremolo_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x17,
      },

      Parameter {
         fx_type = "tremolo",
         name = "Ini phase",
         id = "tremolo_ini_phase",
         max_value = 0x12,
         number = 0x18,
         notify_visibility = {"tremolo_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "tremolo",
         name = "LFO spread",
         id = "tremolo_lfo_spread",
         min_value = -18,
         max_value = 18,
         default_value = 0,
         number = 0x19,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Ctrl 1",
         id = "ring_mod_ctrl_1",
         items = {"fixed freq", "note offset", "lfo int", "lfo freq", "sync note"},
         item_values = {0x2, 0x3, 0x6, 0x8, 0x9},
         number = 0x02,
      },
      Parameter {
         fx_type = "ring mod",
         name = "Ctrl 2",
         id = "ring_mod_ctrl_2",
         items = {"fixed freq", "note offset", "lfo int", "lfo freq", "sync note"},
         item_values = {0x2, 0x3, 0x6, 0x8, 0x9},
         number = 0x03,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Osc mode",
         id = "ring_mod_osc_mode",
         items = {"fixed", "note"},
         item_values = {0, 1},
         number = 0x11,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Fixed freq",
         id = "ring_mod_fixed_freq",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"ring_mod_osc_mode"},
         visibility = function (p)
            return p.value == 1
         end,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Note offset",
         id = "ring_mod_note_offset",
         max_value = 48,
         min_value = -48,
         default_value = 0,
         number = 0x13,
         notify_visibility = {"ring_mod_osc_mode"},
         visibility = function (p)
            return p.value == 2
         end,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Note fine",
         id = "ring_mod_note_fine",
         max_value = 50,
         min_value = -50,
         default_value = 0,
         number = 0x14,
         notify_visibility = {"ring_mod_osc_mode"},
         visibility = function (p)
            return p.value == 2
         end,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Osc wave",
         id = "ring_mod_osc_wave",
         items = {"saw", "triangle", "sine"},
         item_values = {0, 1, 2},
         number = 0x15,
      },

      Parameter {
         fx_type = "ring mod",
         name = "LFO int",
         id = "ring_mod_lfo_int",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x16,
      },

     Parameter {
         fx_type = "ring mod",
         name = "LFO sync",
         id = "ring_mod_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x17,
      },

      Parameter {
         fx_type = "ring mod",
         name = "LFO freq",
         id = "ring_mod_lfo_freq",
         max_value = 127,
         number = 0x18,
         notify_visibility = {"ring_mod_lfo_sync"},
         visibility = function (t)
            return t.value == 1
         end
      },

      Parameter {
         fx_type = "ring mod",
         name = "Sync note",
         id = "ring_mod_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x19,
         notify_visibility = {"ring_mod_lfo_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "ring mod",
         name = "LFO wave",
         id = "ring_mod_lfo_wave",
         items = {"saw", "square", "triangle", "sine", "s&h"},
         item_values = range(0, 4),
         number = 0x1a,
      },

      Parameter {
         fx_type = "ring mod",
         name = "LFO shape",
         id = "ring_mod_lfo_shape",
         max_value = 63,
         min_value = -63,
         default_value = 0,
         number = 0x1b,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Key sync",
         id = "ring_mod_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x1c,
      },

      Parameter {
         fx_type = "ring mod",
         name = "Ini phase",
         id = "ring_mod_ini_phase",
         max_value = 0x12,
         number = 0x1d,
         notify_visibility = {"ring_mod_key_sync"},
         visibility = function (t)
            return t.value == 2
         end
      },

      Parameter {
         fx_type = "ring mod",
         name = "Pre LPF",
         id = "ring_mod_pre_lpf",
         max_value = 127,
         number = 0x1e,
      },

      Parameter {
         fx_type = "grain sft",
         name = "Ctrl 1",
         id = "grain_sft_ctrl_1",
         items = {"TM ratio", "TM ratio (sync)", "lfo freq", "sync note"},
         item_values = {0x2, 0x4, 0x7, 0x8},
         number = 0x02,
      },

      Parameter {
         fx_type = "grain sft",
         name = "Ctrl 2",
         id = "grain_sft_ctrl_2",
         items = {"TM ratio", "TM ratio (sync)", "lfo freq", "sync note"},
         item_values = {0x2, 0x4, 0x7, 0x8},
         number = 0x03,
      },
    
      Parameter {
         fx_type = "grain sft",
         name = "BPM sync",
         id = "grain_sft_bpm_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x11,
      },
      
      Parameter {
         fx_type = "grain sft",
         name = "TM ratio",
         id = "grain_sft_tm_ratio",
         max_value = 127,
         number = 0x12,
         notify_visibility = {"grain_sft_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "Duration",
         id = "grain_sft_duration",
         max_value = 127,
         number = 0x13,
         notify_visibility = {"grain_sft_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 1
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "TM ratio (sync)",
         id = "grain_sft_tm_ratio_sync",
         max_value = 0xe,
         number = 0x14,
         notify_visibility = {"grain_sft_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "Duration",
         id = "grain_sft_duration_sync",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x15,
         notify_visibility = {"grain_sft_bpm_sync"},
         visibility = function (bpm_sync)
            return bpm_sync.value == 2
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "LFO sync",
         id = "grain_sft_lfo_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x16,
      },

      Parameter {
         fx_type = "grain sft",
         name = "LFO freq",
         id = "grain_sft_lfo_freq",
         max_value = 127,
         number = 0x17,
         notify_visibility = {"grain_sft_lfo_sync"},
         visibility = function (p)
            return p.value == 1
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "Sync note",
         id = "grain_sft_lfo_sync_note",
         items = sync_notes,
         item_values = range(0, (#sync_notes)-1),
         number = 0x18,
         notify_visibility = {"grain_sft_lfo_sync"},
         visibility = function (p)
            return p.value == 1
         end
      },

      Parameter {
         fx_type = "grain sft",
         name = "Key sync",
         id = "grain_sft_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x19,
      },

      Parameter {
         fx_type = "grain sft",
         name = "Ini phase",
         id = "grain_sft_ini_phase",
         max_value = 0x12,
         number = 0x1a,
         notify_visibility = {"grain_sft_key_sync"},
         visibility = function (p)
            return p.value == 2
         end
      },

   }

   return r
end

local fx_data_map = {



   [0x11f] = function (value)
      return {{"type", value % 0x10}}
   end,
   [0x121] = function (value)
      return {{"comp_ctrl_1", value},
              {"filter_ctrl_1", value},
              {"bandeq_ctrl_1", value},
              {"distortion_ctrl_1", value},
              {"decimator_ctrl_1", value},
              {"delay_ctrl_1", value},
              {"lcr_delay_ctrl_1", value},
              {"pan_delay_ctrl_1", value},
              {"mod_delay_ctrl_1", value},
              {"tape_echo_ctrl_1", value},
              {"chorus_ctrl_1", value},
              {"flanger_ctrl_1", value},
              {"phaser_ctrl_1", value},
              {"vibrato_ctrl_1", value},
              {"tremolo_ctrl_1", value},
              {"ring_mod_ctrl_1", value},
              {"grain_sft_ctrl_1", value}}
   end,
   [0x122] = function (value)
      return {{"comp_ctrl_2", value},
              {"filter_ctrl_2", value},
              {"bandeq_ctrl_2", value},
              {"distortion_ctrl_2", value},
              {"decimator_ctrl_2", value},
              {"delay_ctrl_2", value},
              {"lcr_delay_ctrl_2", value},
              {"pan_delay_ctrl_2", value},
              {"mod_delay_ctrl_2", value},
              {"tape_echo_ctrl_2", value},
              {"chorus_ctrl_2", value},
              {"flanger_ctrl_2", value},
              {"phaser_ctrl_2", value},
              {"vibrato_ctrl_2", value},
              {"tremolo_ctrl_1", value},
              {"ring_mod_ctrl_2", value},
              {"grain_sft_ctrl_2", value}}
   end,
   [0x123] = "dry_wet",
   [0x124] = function (value)
      return {{"comp_env_sel", value},
              {"filter_type", value},
              {"bandeq_trim", value},
              {"distortion_gain", value},
              {"decimator_pre_lpf", value},
              {"delay_type", value},
              {"lcr_delay_bpm_sync", value},
              {"pan_delay_bpm_sync", value},
              {"mod_delay_bpm_sync", value},
              {"tape_echo_bpm_sync", value},
              {"chorus_mod_depth", value},
              {"flanger_delay", value},
              {"phaser_type", value},
              {"vibrato_mod_depth", value},
              {"tremolo_mod_depth", value},
              {"ring_mod_osc_mode", value},
              {"grain_sft_bpm_sync", value}}
   end,
   [0x125] = function (value)
      return {{"comp_sens", value},
              {"filter_cutoff", value},
              {"bandeq_b1_type", value},
              {"distortion_pre_freq", value},
              {"decimator_hi_damp", value},
              {"delay_bpm_sync", value},
              {"lcr_delay_tm_ratio", value},
              {"pan_delay_tm_ratio", value},
              {"mod_delay_tm_ratio", value},
              {"tape_echo_tm_ratio", value},
              {"chorus_lfo_freq", value},
              {"flanger_mod_depth", value},
              {"phaser_manual", value},
              {"vibrato_lfo_sync", value},
              {"tremolo_lfo_sync", value},
              {"ring_mod_fixed_freq", value},
              {"grain_sft_tm_ratio", value}}
   end,
   [0x126] = function (value)
      local domin8or_workaround = value - 0x40
      if domin8or_workaround < -18 or domin8or_workaround > 18 then
         domin8or_workaround = -18
      end
      return {{"comp_attack", value},
              {"filter_reso", value},
              {"bandeq_b1_freq", value},
              {"distortion_pre_q", value},
              {"decimator_fs", value},
              {"delay_tm_ratio", value},
              {"lcr_delay_l_delay", value},
              {"pan_delay_l_delay", value},
              {"mod_delay_l_delay", value},
              {"tape_echo_1_delay", value},
              {"chorus_lfo_spread", domin8or_workaround},
              {"flanger_feedback", value},
              {"phaser_mod_depth", value},
              {"vibrato_lfo_freq", value},
              {"tremolo_lfo_freq", value},
              {"ring_mod_note_offset", value - 0x40},
              {"grain_sft_duration", value}}
   end,
   [0x127] = function (value)
      return {{"comp_out_level", value},
              {"filter_trim", value},
              {"bandeq_b1_q", value},
              {"distortion_pre_gain", value - 0x40},
              {"decimator_bit", value},
              {"delay_l_delay", value},
              {"lcr_delay_c_delay", value},
              {"pan_delay_r_delay", value},
              {"mod_delay_r_delay", value},
              {"tape_echo_2_delay", value},
              {"chorus_pre_delay_l", value},
              {"flanger_phase", value},
              {"phaser_reso", value},
              {"vibrato_lfo_sync_note", value},
              {"tremolo_lfo_sync_note", value},
              {"ring_mod_note_fine", value - 0x40},
              {"grain_sft_tm_ratio_sync", value}}
   end,
   [0x128] = function (value)
      return {{"filter_mod_src", value},
              {"bandeq_b1_gain", value - 0x40},
              {"distortion_b1_freq", value},
              {"decimator_out_level", value},
              {"delay_r_delay", value},
              {"lcr_delay_r_delay", value},
              {"pan_delay_tm_ratio_sync", value},
              {"mod_delay_tm_ratio_sync", value},
              {"tape_echo_tm_ratio_sync", value},
              {"chorus_pre_delay_r", value},
              {"flanger_lfo_sync", value},
              {"vibrato_lfo_wave", value},
              {"phaser_phase", value},
              {"tremolo_lfo_wave", value},
              {"ring_mod_osc_wave", value},
              {"grain_sft_duration_sync", value}}
   end,
   [0x129] = function (value)
      return {{"filter_mod_int", value - 0x40},
              {"bandeq_b2_freq", value},
              {"distortion_b1_q", value},
              {"decimator_fs_mod_int", value - 0x40},
              {"delay_tm_ratio_sync", value},
              {"lcr_delay_tm_ratio_sync", value},
              {"pan_delay_l_delay_sync", value},
              {"mod_delay_l_delay_sync", value},
              {"tape_echo_1_delay_sync", value},
              {"chorus_trim", value},
              {"flanger_lfo_freq", value},
              {"vibrato_lfo_shape", value - 0x40},
              {"phaser_lfo_sync", value},
              {"tremolo_lfo_shape", value - 0x40},
              {"ring_mod_lfo_int", value - 0x40},
              {"grain_sft_lfo_sync", value}}
   end,
   [0x12a] = function (value)
      return {{"filter_resp", value},
              {"bandeq_b2_q", value},
              {"decimator_lfo_sync", value},
              {"delay_l_delay_sync", value},
              {"lcr_delay_l_delay_sync", value},
              {"pan_delay_r_delay_sync", value},
              {"mod_delay_r_delay_sync", value},
              {"tape_echo_2_delay_sync", value},
              {"chorus_hi_eq_gain", value - 0x40},
              {"flanger_lfo_sync_note", value},
              {"vibrato_key_sync", value},
              {"phaser_lfo_freq", value},
              {"tremolo_key_sync", value},
              {"ring_mod_lfo_sync", value},
              {"grain_sft_lfo_freq", value}}
   end,
   [0x12b] = function (value)
      return {{"filter_lfo_sync", value},
              {"bandeq_b2_gain", value - 0x40},
              {"decimator_lfo_freq", value},
              {"delay_r_delay_sync", value},
              {"lcr_delay_c_delay_sync", value},
              {"pan_delay_feedback", value},
              {"mod_delay_feedback", value},
              {"tape_echo_1_lvl", value},
              {"flanger_lfo_wave", value},
              {"vibrato_ini_phase", value},
              {"phaser_lfo_sync_note", value},
              {"tremolo_ini_phase", value},
              {"ring_mod_lfo_freq", value},
              {"grain_sft_lfo_sync_note", value}}
   end,
   [0x12c] = function (value)
      return {{"filter_lfo_freq", value},
              {"bandeq_b3_freq", value},
              {"decimator_sync_note", value},
              {"delay_feedback", value},
              {"lcr_delay_r_delay_sync", value},
              {"pan_delay_mod_depth", value},
              {"mod_delay_mod_depth", value},
              {"tape_echo_2_lvl", value},
              {"flanger_lfo_shape", value - 0x40},
              {"vibrato_lfo_spread", value - 0x40},
              {"phaser_lfo_wave", value},
              {"tremolo_lfo_spread", value - 0x40},
              {"ring_mod_lfo_sync_note", value},
              {"grain_sft_key_sync", value}}
   end,
   [0x12d] = function (value)
      return {{"filter_lfo_sync_note", value},
              {"bandeq_b3_q", value},
              {"decimator_lfo_wave", value},
              {"delay_hi_damp", value},
              {"lcr_delay_l_level", value},
              {"pan_delay_lfo_sync", value},
              {"mod_delay_lfo_freq", value},
              {"tape_echo_feedback", value},
              {"flanger_key_sync", value},
              {"phaser_lfo_shape", value - 0x40},
              {"ring_mod_lfo_wave", value},
              {"grain_sft_ini_phase", value}}
   end,
   [0x12e] = function (value)
      return {{"filter_lfo_wave", value},
              {"bandeq_b3_gain", value - 0x40},
              {"decimator_lfo_shape", value - 0x40},
              {"delay_trim", value},
              {"lcr_delay_c_level", value},
              {"pan_delay_lfo_freq", value},
              {"mod_delay_lfo_spread", value - 0x40},
              {"tape_echo_hi_damp", value},
              {"flanger_ini_phase", value},
              {"phaser_key_sync", value},
              {"ring_mod_lfo_shape", value - 0x40}}
   end,
   [0x12f] = function (value)
      return {{"filter_lfo_shape", value - 0x40},
              {"bandeq_b4_type", value},
              {"decimator_key_sync", value},
              {"delay_spread", value},
              {"lcr_delay_r_level", value},
              {"pan_delay_lfo_sync_note", value},
              {"tape_echo_lo_damp", value},
              {"flanger_lfo_spread", value - 0x40},
              {"phaser_ini_phase", value},
              {"ring_mod_key_sync", value}}
   end,
   [0x130] = function (value)
      return {{"filter_key_sync", value},
              {"bandeq_b4_freq", value},
              {"lcr_delay_c_feedback", value},
              {"pan_delay_lfo_wave", value},
              {"tape_echo_trim", value},
              {"flanger_hi_damp", value},
              {"phaser_lfo_spread", value - 0x40},
              {"ring_mod_ini_phase", value}}
   end,
   [0x131] = function (value)
      return {{"filter_ini_phase", value},
              {"bandeq_b3_q", value},
              {"lcr_delay_trim", value},
              {"pan_delay_lfo_shape", value - 0x40},
              {"tape_echo_saturation", value},
              {"phaser_hi_damp", value},
              {"ring_mod_pre_lpf", value}}
   end,
   [0x132] = function (value)
      return {{"bandeq_b3_gain", value - 0x40},
              {"lcr_delay_spread", value},
              {"pan_delay_key_sync", value},
              {"tape_echo_wow_freq", value}}
   end,
   [0x133] = function (value)
      return {{"pan_delay_ini_phase", value},
              {"tape_echo_wow_depth", value}}
   end,
   [0x134] = function (value)
      return {{"pan_delay_lfo_spread", value - 0x40},
              {"tape_echo_pre_tone", value}}
   end,
   [0x135] = function (value)
      return {{"pan_delay_hi_damp", value},
              {"tape_echo_spread", value}}
   end,
   [0x136] = function (value)
      return {{"pan_delay_trim", value}}
   end,
}

function get_fx_map(fx)
   local ret = {}
   local suffix = ("_fx%d"):format(fx)
   for k, v in pairs(fx_data_map) do
      if type(v) == "string" then
         ret[k + (fx-1)*0x18] = v .. suffix
      else
         ret[k + (fx-1)*0x18] = function (value)
            local r = v(value)
            for i, w in ipairs(r) do
               w[1] = w[1] .. suffix
            end
            return r
         end
      end
   end
   return ret
end

local all_section = Section {
   name = "All",
   Group {
      name = "Common",
      sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x00, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
      Parameter {
         name = "Voice mode",
         id = "voice_mode",
         items = {"single", "layer", "split", "multi"},
         item_values = range(0, 4),
         number = 0x19,
      },
      Parameter {
         name = "T2 MIDI channel",
         id = "t2_midi_ch",
         items = {"Global", "1", "2", "3", "4", "5", "6", "7", "8",
                  "9", "10", "11", "12", "13", "14", "15", "16"},
         item_values = {0x10, unpack(range(0, 15))},
         number = 0x1a,
      },
      Parameter {
         name = "Split key",
         id = "split_key",
         max_value = 127,
         min_value = 0,
         default_value = 63,
         number = 0x1b,
      },
      Parameter {
         name = "Scale",
         id = "scale",
         items = {"equal", "major", "minor", "arabic", "pytha",
                  "werck", "kirn", "splendoro", "prelog", "user"},
         item_values = range(0, 9),
         number = 0x17,
      },
      Parameter {
         name = "Scale key",
         id = "scale_key",
         items = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"},
         item_values = range(0, 11),
         number = 0x1e,
      },
   },
   Group {
      name = "Knob",
      Parameter {
         name = "Assign 1",
         id = "assign1",
         items = knob_values,
         item_values = range(0, 0x36),
         number = 0,
      },
      Parameter {
         name = "Assign 2",
         id = "assign2",
         items = knob_values,
         item_values = range(0, 0x36),
         number = 1,
      },
      Parameter {
         name = "Assign 3",
         id = "assign3",
         items = knob_values,
         item_values = range(0, 0x36),
         number = 2,
      },
   },
   Group {
      name = "Octave",
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x00, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "Octave",
         id = "octave",
         min_value = -3,
         max_value = 3,
         default_value = 0,
         number = 0x1d,
      },
   },
   Group {
      name = "Vocoder",
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x40, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "ON/OFF",
         id = "vocoder_on_off",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x00,
      },
   },
   Group {
      name = "Arp",
      sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x61, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x60, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "ON/OFF",
         id = "arp_on_off",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x01,
      },
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x60, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "Tempo",
         id = "arp_tempo",
         max_value = 300,
         min_value = 20,
         default_value = 120,
         number = 0x00,
      },
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x00, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "Assign",
         id = "arp_assign",
         items = {"timbre 1", "timbre 2", "timbre 1+2"},
         item_values = {0, 1, 2},
         number = 0x18,
      },
      Parameter {
         name = "Type",
         id = "arp_type",
         items = {"up", "down", "alt1", "alt2", "random", "trigger"},
         item_values = range(0, 5),
         number = 0x00,
      },
      Parameter {
         name = "Latch",
         id = "arp_latch",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x06,
      },
      Parameter {
         name = "Oct range",
         id = "arp_oct_range",
         items = {"1", "2", "3", "4"},
         item_values = range(0, 3),
         number = 0x02,
      },
      Parameter {
         name = "Last step",
         id = "arp_last_step",
         items = {"1", "2", "3", "4", "5", "6", "7", "8"},
         item_values = range(0, 7),
         default_value = 8,
         number = 0x03,
      },
      Parameter {
         name = "Gate time",
         id = "arp_gate_time",
         max_value = 100,
         default_value = 50,
         number = 0x04,
      },
      Parameter {
         name = "Swing",
         id = "arp_swing",
         max_value = 50,
         min_value = -50,
         default_value = 0,
         number = 0x05,
      },
      Parameter {
         name = "Resolution",
         id = "arp_resolution",
         items = {"1/32", "1/24", "1/16", "1/12", "1/8", "1/6", "1/4", "1/2", "1/1"},
         item_values = range(0, 8),
         default_value = 7,
         number = 0x01,
      },
      Parameter {
         sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x60, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
         name = "Key sync",
         id = "arp_key_sync",
         items = {"off", "on"},
         item_values = {0, 1},
         number = 0x02,
      },
   },
   Group {
      name = "Arp notes",
      sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x61, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
      Parameter {
         name = "Note 1",
         id = "arp_note_1",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x10,
      },
      Parameter {
         name = "Note 2",
         id = "arp_note_2",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x11,
      },
      Parameter {
         name = "Note 3",
         id = "arp_note_3",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x12,
      },
      Parameter {
         name = "Note 4",
         id = "arp_note_4",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x13,
      },
      Parameter {
         name = "Note 5",
         id = "arp_note_5",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x14,
      },
      Parameter {
         name = "Note 6",
         id = "arp_note_6",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x15,
      },
      Parameter {
         name = "Note 7",
         id = "arp_note_7",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x16,
      },
      Parameter {
         name = "Note 8",
         id = "arp_note_8",
         items = {"off", "on"},
         item_values = {0, 1},
         default_value = 2,
         number = 0x17,
      },
   }
}

local def = {
   id = "microkorg_xl",
   name = "MicroKORG XL",
   author = "Valentin David <valentin.david@gmail.com>",
   sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x11, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
   beta = true,
   content_height = 700,
   data_map = merge_tables(get_timbre_data_map(1),
                           get_timbre_data_map(2),
                           get_fx_map(1),
                           get_fx_map(2),
                           {[0x09] = function (value)
                               return {{"voice_mode", math.floor(value/0x40)},
                                       {"arp_assign", math.floor(value/0x10)%4}}
                           end,
                            [0x0d] = function (value)
                               return {{"scale", value%0x10},
                                       {"scale_key", math.floor(value/0x10)}}
                            end,
                            [0x0e] = "t2_midi_ch",
                            [0x0f] = "split_key",
                            [0x10] = function (value)
                               return {{"octave", math.floor(value/0x10) - 0x8}}
                            end,
                            [0x11] = "assign1",
                            [0x12] = "assign2",
                            [0x13] = "assign3",
                            [0xd1] = function (value)
                               return {{"vocoder_on_off", math.floor(value/0x80)}}
                            end,
                            [0x14f] = function (value, other_values)
                               return {{"arp_tempo", value + other_values[0x150]*256}}
                            end,
                            [0x150] = function (value, other_values)
                               return {{"arp_tempo", other_values[0x14f] + value*256}}
                            end,
                            [0x151] = function (value)
                               return {{"arp_key_sync", math.floor(value/0x40)%2},
                                       {"arp_on_off", math.floor(value/0x80)}}
                            end,
                            [0x153] = function (value)
                               return {{"arp_type", value%8},
                                       {"arp_resolution", math.floor(value/0x10)}}
                            end,
                            [0x154] = function (value)
                               return {{"arp_latch", math.floor(value/0x80)},
                                       {"arp_oct_range", math.floor(value/0x20)%4},
                                       {"arp_last_step", value%8}}
                            end,
                            [0x155] = "arp_gate_time",
                            [0x156] = function (value)
                               return {{"arp_swing", value - 0x40}}
                            end,
                            [0x157] = function (value)
                               return {{"arp_note_1", value%2},
                                       {"arp_note_2", math.floor(value/0x02)%2},
                                       {"arp_note_3", math.floor(value/0x04)%2},
                                       {"arp_note_4", math.floor(value/0x08)%2},
                                       {"arp_note_5", math.floor(value/0x10)%2},
                                       {"arp_note_6", math.floor(value/0x20)%2},
                                       {"arp_note_7", math.floor(value/0x40)%2},
                                       {"arp_note_8", math.floor(value/0x80)}}
                            end,                            
                           }),
}

table.insert(def, all_section)

for i, v in ipairs({get_timbre_sections(1)}) do
   table.insert(def, v)
end

for i, v in ipairs({get_timbre_sections(2)}) do
   table.insert(def, v)

end

local fx_section = Section {
   sysex_message_template = {0xF0, 0x42, 0x30, 0x7e, 0x41, 0x50, 0x00, "lnn", "hnn", "lvv", "hvv", 0xF7},
   name = "Master FX",
   get_fx_group(1),
   get_fx_group(2)
}      

table.insert(def, fx_section)

return MKDefinition(def)

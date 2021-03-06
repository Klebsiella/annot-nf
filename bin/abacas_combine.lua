#!/usr/bin/env gt

--[[
  Copyright (c) 2014 Sascha Steinbiss <ss34@sanger.ac.uk>
  Copyright (c) 2014 Genome Research Ltd

  Permission to use, copy, modify, and distribute this software for any
  purpose with or without fee is hereby granted, provided that the above
  copyright notice and this permission notice appear in all copies.

  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]

function usage()
  io.stderr:write(string.format("Usage: %s <ABACAS directory> <outfileprefix> "
                                .. "<chromosome pattern> <chr prefix> "
                                .. "<bin seqid> <seq prefix>\n" , arg[0]))
  os.exit(1)
end

if #arg ~= 6 then
  usage()
end

abacas_dir = arg[1]
outfileprefix = arg[2]
refpat = arg[3]
chrprefix = arg[4]
binseqid = arg[5]
seqprefix = arg[6]

package.path = gt.script_dir .. "/?.lua;" .. package.path
require("lib")
require("lfs")

-- scaffold datastructures
scafs = {}
-- pseudochromosomes
pseudochr_seq = {}

-- parse contigs and gaps
for file in lfs.dir(arg[1]) do
  if file:match("^Res\.(.+)\.gff") then
    local seqid = file:match("^Res\.(.+).contigs\.gff")
    local keys, seqs = get_fasta_nosep(arg[1] .. "/Res." .. seqid .. ".fna")
    pseudochr_seq[seqid] = seqs[seqid]
    scafs[seqid] = {}
    for l in io.lines(file) do
      if string.sub(l, 1, 1) ~= '#' then
        _, type1, type2, start, stop, frame, strand, _, attr =
                                                         unpack(split(l, "%s+"))
        if not attr then
          io.stderr:write("non-comment line with <9 columns: " .. l .. "\n")
          os.exit(1)
        end
        if type1 == "Contig" then
          -- this is a 'scaffold'
          this_scaf = {start = start,
                       stop = stop,
                       seq = string.sub(seqs[seqid], start, stop),
                       contigs = {}}
          local i_end = 0
          -- gather all 'contigs'
          while true do
            i_start, i_end = string.find(this_scaf.seq, "[^Nn]+", i_end + 1)
            if i_start == nil then break end
            this_contig = {start = i_start,
                           stop = i_end,
                           seq = string.sub(this_scaf.seq, i_start, i_end)}
            -- sanity check
            if this_contig.seq:match("[Nn]") then
              io.stderr:write("contig with N character encountered")
              os.exit(1)
            end
            table.insert(this_scaf.contigs, this_contig)
          end
          table.insert(scafs[seqid], this_scaf)
        elseif type1 == "GAP" then
          -- just a sanity check
          gapseq = string.sub(seqs[seqid], start, stop)
          if gapseq:match("[^Nn]") then
            io.stderr:write("Gap with non-N character encountered")
            os.exit(1)
          end
        end
      end
    end
  end
end

ref_target_chromosome_map = {}

-- ensure correct naming for all sequences
newscafs = {}
newkeys = {}
newpseudochr_seq = {}
for k,v in pairs(scafs) do
  local chr = tonumber(k:match(refpat))
  local newid =  chrprefix .. "_" .. string.format("%02d", chr)
  newscafs[newid] = v
  newpseudochr_seq[newid] = pseudochr_seq[k]
  table.insert(newkeys, newid)
  ref_target_chromosome_map[chr] = {k, newid}
end
scafs = newscafs
keys = newkeys
pseudochr_seq = newpseudochr_seq

-- handle 'bin' seqs
scafs[binseqid] = {}
start = 1
stop = 1
binkeys, binseqs = get_fasta_nosep(arg[1] .. "/Res.abacasBin.fna")
tmp = {}
if #binkeys > 0 then
  table.insert(newkeys, binseqid)
  for k,v in pairs(binseqs) do
    stop = start + string.len(v) - 1
    this_scaf ={start = tonumber(start),
                stop = tonumber(stop),
                seq = v,
                contigs = {}}
    local i_end = 0
    while true do
      i_start, i_end = string.find(this_scaf.seq, "[^Nn]+", i_end + 1)
      if i_start == nil then break end
      this_contig = {start = i_start,
                     stop = i_end,
                     seq = string.sub(this_scaf.seq, i_start, i_end)}
      table.insert(this_scaf.contigs, this_contig)
    end
    table.insert(scafs[binseqid], this_scaf)
    if start > 1 then
      table.insert(tmp, string.rep("N",100))
    end
    start = stop + 1 + 100
    table.insert(tmp, v)
  end
  pseudochr_seq[binseqid] = table.concat(tmp,"")
end

-- open files
pseudochr_fasta_out = io.open(outfileprefix .. ".pseudochr.fasta", "w+")
scaf_fasta_out = io.open(outfileprefix .. ".scafs.fasta", "w+")
scaf_agp_out = io.open(outfileprefix .. ".pseudochr.agp", "w+")
scaf_agp_out:write("##agp-version\t2.0\n")
ctg_fasta_out = io.open(outfileprefix .. ".contigs.fasta", "w+")
ctg_agp_out = io.open(outfileprefix .. ".scafs.agp", "w+")
ctg_agp_out:write("##agp-version\t2.0\n")
ref_target_mapping_out = io.open("ref_target_mapping.txt", "w+")

-- do the output
scaf_i = 1
contig_i = 1
table.sort(newkeys)
-- for all toplevel seqs...
for _,seqid in ipairs(newkeys) do
  pseudochr_fasta_out:write(">" .. seqid .. "\n")
  print_max_width(pseudochr_seq[seqid], pseudochr_fasta_out, 60)
  print(seqid .. ":  " .. #scafs[seqid])
  local i = 1
  local s_last_stop = 0
  for _, s in ipairs(scafs[seqid]) do
    local scafname = seqprefix .. "_SCAF" .. string.format("%06d", scaf_i)
    scaf_fasta_out:write(">" .. scafname .. "\n")
    print_max_width(s.seq, scaf_fasta_out, 60)
    if s_last_stop > 0 then
      scaf_agp_out:write(seqid .. "\t" .. tonumber(s_last_stop)+1 .. "\t"
                        .. tonumber(s.start)-1 .. "\t" .. i .. "\tU\t"
                        .. (tonumber(s.start)-1)-(tonumber(s_last_stop)+1) + 1
                        .. "\tcontig\tno\talign_xgenus\n")
      i = i + 1
    end
    scaf_agp_out:write(seqid .. "\t" .. s.start .. "\t"
                       .. s.stop .. "\t" .. i .. "\tF\t" .. scafname
                       .. "\t1\t" .. string.len(s.seq) .. "\t+\n")
    scaf_i = scaf_i + 1
    local j = 1
    local c_last_stop = 0
    for _, c in ipairs(s.contigs) do
      local ctgname = seqprefix .. "_CTG" .. string.format("%06d", contig_i)
      ctg_fasta_out:write(">" .. ctgname .. "\n")
      print_max_width(c.seq, ctg_fasta_out, 60)
      if c_last_stop > 0 then
        ctg_agp_out:write(scafname .. "\t" .. tonumber(c_last_stop)+1 .. "\t"
                          .. tonumber(c.start)-1 .. "\t" .. j .. "\tN\t"
                          .. (tonumber(c.start)-1)-(tonumber(c_last_stop)+1) + 1
                          .. "\tscaffold\tyes\tunspecified\n")
        j = j + 1
      end
      ctg_agp_out:write(scafname .. "\t" .. c.start .. "\t"
                        .. c.stop .. "\t" .. j .. "\tF\t" .. ctgname
                        .. "\t1\t" .. string.len(c.seq) .. "\t+\n")
      contig_i = contig_i + 1
      j = j + 1
      c_last_stop = c.stop
    end
    i = i + 1
    s_last_stop = tonumber(s.stop)
  end
end

for k,v in pairs(ref_target_chromosome_map) do
  ref_target_mapping_out:write(k .. "\t" .. v[1] .. "\t" .. v[2] .. "\n")
end
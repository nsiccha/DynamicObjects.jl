using TestItemRunner

# The notes DO writes into progress nodes (`from disk: …`, `queued · #k`, `(cached)`) are
# Treebars notes, written in the language of the page that renders the node (DO snag
# `german-htmxobjec-e76f2d8f`, Treebars snag `consumer-written-813ef5a6`). A node is shared
# by every viewer and often written from a background task, so DO cannot pick the language
# when it writes. `render_text` writes English, byte-identical to the strings DO wrote before.
@testmodule ProgressNoteFixtures begin
using DynamicObjects
import DynamicObjects.Treebars
export PNStore, PNReader, note_text, node_of

const PN_BASE = mktempdir()

@dynamicstruct struct PNStore
    tag::Symbol
    __cache_base__ = PN_BASE
    "Load the store"
    @cached payload = fill(1.5, 3_600)
end

@dynamicstruct struct PNReader
    store::PNStore
    "Read the payload"
    read_payload = @fetch!(__status__, store.payload)
end

# How a page in `lang` writes the note `m` (`Treebars._note_text` is what every HTML
# renderer calls; the HTML renderers live in Treebars' HTMXObjects extension, which DO's
# test environment does not load).
note_text(m, lang) = Treebars._note_text(m, Treebars.treebar_texts(lang))

"The progress node of bare property `name`'s computation on `o`."
node_of(o, name::Symbol) = DynamicObjects._status_of(getfield(o, :cache).cache, name)
end

@testitem "progress notes: English is unchanged, German follows the page" tags=[:progress] setup=[ProgressNoteFixtures] begin
using .ProgressNoteFixtures
using DynamicObjects
import DynamicObjects.Treebars
notes = DynamicObjects.progress_notes
# The strings DO wrote before (`_format_size`'s bands: one decimal, binary units).
for (n, en, de) in ((42, "42 B", "42 B"), (870_400, "850.0 KB", "850,0 KB"),
                    (28_206_694, "26.9 MB", "26,9 MB"), (3 * 1024^3, "3.0 GB", "3,0 GB"))
    m = notes(:from_disk; size = Treebars.ByteSize(n))
    @test note_text(m, :en) == "from disk: $en"
    @test note_text(m, :de) == "aus dem Zwischenspeicher ($de)"
end
@test note_text(notes(:cached), :en) == "(cached)"
@test note_text(notes(:cached), :de) == "(zwischengespeichert)"
q = Treebars.treebar_note(:queued_position; position = 2)
@test note_text(q, :en) == "queued · #2"
@test note_text(q, :de) == "wartet · Nr. 2"
# An app rewords a note by passing DO's table to its texts.
texts = Treebars.treebar_texts(:de, notes => (from_disk = "von der Festplatte ({size})",))
@test Treebars._note_text(notes(:from_disk; size = Treebars.ByteSize(28_206_694)), texts) ==
    "von der Festplatte (26,9 MB)"
end

@testitem "progress notes: a disk load and an in-memory hit write notes, not English" tags=[:progress] setup=[ProgressNoteFixtures] begin
using .ProgressNoteFixtures
using DynamicObjects
import DynamicObjects.Treebars
using DynamicObjects.Treebars: render_text
PNStore(:disk).payload                    # writes the @cached file
# A fresh instance reads it back from disk: its node's note is the size it loaded.
fresh = PNStore(:disk)
@test fresh.payload == fill(1.5, 3_600)
node = node_of(fresh, :payload)
@test node.impl.message isa Treebars.TreebarNote
kb = round(filesize(@cache_path fresh.payload) / 1024, digits = 1)
@test 1 < kb < 1024
@test note_text(node.impl.message, :en) == "from disk: $kb KB"
@test note_text(node.impl.message, :de) == "aus dem Zwischenspeicher ($(replace(string(kb), '.' => ',')) KB)"
@test startswith(render_text(node), "✓ Load the store — from disk: $kb KB")
# A reader threading its read finds the value in memory: the node's label stays the
# property's docstring, and its note says it was cached.
r = PNReader(fresh)
@test r.read_payload == fill(1.5, 3_600)
hit = node_of(fresh, :payload)
@test hit === node                        # the one shared node
@test contains(render_text(node_of(r, :read_payload)), "Load the store — (cached)")
@test hit.impl.description == "Load the store"
@test note_text(hit.impl.message, :en) == "(cached)"
@test note_text(hit.impl.message, :de) == "(zwischengespeichert)"
# A second hit (a repeat poll) leaves it as it is.
@test PNReader(fresh).read_payload == fill(1.5, 3_600)
@test hit.impl.description == "Load the store"
@test note_text(hit.impl.message, :en) == "(cached)"
end

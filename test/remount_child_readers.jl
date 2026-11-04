using TestItemRunner

@testmodule RemountChildReaders begin
using DynamicObjects
export ReaderRoot, DeepRoot, OpaqueMemberRoot, ExternalChildRoot, DefaultedChildRoot,
       ForwardingRoot, PinnedRoot, RCR_CALLS, rcr_reset!, rcr_bump!, rcr_context_names

const RCR_CALLS = Dict{Symbol,Int}()
const RCR_LOCK = ReentrantLock()
rcr_bump!(k) = lock(() -> (RCR_CALLS[k] = get(RCR_CALLS, k, 0) + 1), RCR_LOCK)
rcr_reset!() = (empty!(RCR_CALLS); nothing)
rcr_context_names(view) = getfield(view, :cache).cache.invalidated

_rcr_holds(child) = child
_rcr_reads(o) = o.value

# `ctx` is what every remount rebinds. Each reader declares what it reads of an
# inline child: the counts then say whether that reader is shared or per view.
@dynamicstruct struct ReaderRoot
    ctx = nothing
    plain = 10
    @struct pins = begin
        shared = (rcr_bump!(:pin_shared); 41)
        on_parent = (rcr_bump!(:pin_on_parent); plain + 1)
        on_context = (rcr_bump!(:pin_on_context); ctx)
        through = (rcr_bump!(:pin_through); on_context)
    end
    @struct run(k::Int) = begin
        fit() = (rcr_bump!(:run_fit); k * 2)
        scoped = (ctx, k)
    end
    # Decided by what they read: these are shared.
    model = (rcr_bump!(:model); pins.shared + 1)
    fit = (rcr_bump!(:fit); model * 2)
    @fresh shown() = fit
    on_parent_reader = (rcr_bump!(:on_parent_reader); pins.on_parent)
    indexed_reader = (rcr_bump!(:indexed_reader); run(3).fit())
    destructured = begin
        rcr_bump!(:destructured)
        (; shared) = pins
        shared + 2
    end
    # These read context through the child: they stay per view, with the right value.
    context_reader = (rcr_bump!(:context_reader); pins.on_context)
    through_reader = (rcr_bump!(:through_reader); pins.through)
    forwarded_reader = (rcr_bump!(:forwarded_reader); pins.ctx)
    indexed_context_reader = (rcr_bump!(:indexed_context_reader); run(3).scoped)
    destructured_context = begin
        rcr_bump!(:destructured_context)
        (; on_context) = pins
        on_context
    end
    # A later read that only becomes context through a sibling the first pass added.
    downstream = (rcr_bump!(:downstream); context_reader)
    # These hold the instance, which holds one request's view.
    holder = (rcr_bump!(:holder); _rcr_holds(pins))
    argument_reader = (rcr_bump!(:argument_reader); run(ctx === nothing ? 1 : ctx).fit())
end

@dynamicstruct struct DeepRoot
    ctx = nothing
    @struct outer = begin
        @struct inner = begin
            deep = (rcr_bump!(:deep); 5)
            deep_context = ctx
        end
    end
    deep_reader = (rcr_bump!(:deep_reader); outer.inner.deep)
    deep_context_reader = (rcr_bump!(:deep_context_reader); outer.inner.deep_context)
end

# A child member that hands its `__self__` to outside code cannot be proven free
# of context, so what reads it stays per view.
@dynamicstruct struct OpaqueMemberRoot
    ctx = nothing
    @struct child = begin
        value = ctx
        handed = _rcr_reads(__self__)
    end
    reader = (rcr_bump!(:opaque_reader); child.handed)
end

@dynamicstruct struct ExternalChild
    arg = 0
    value = (rcr_bump!(:external_value); arg + 1)
end

# An external child is what its constructor call builds under the view. Its
# readers are opaque: shared while the construction reads no context.
@dynamicstruct struct ExternalChildRoot
    ctx = 0
    @include constant = ExternalChild(; arg = 1)
    @include scoped = ExternalChild(; arg = ctx)
    reader = (rcr_bump!(:external_reader); constant.value)
    scoped_reader = (rcr_bump!(:external_scoped_reader); scoped.value)
end

# A keyword default that is code runs under the view, so it may read context.
@dynamicstruct struct DefaultedChildRoot
    ctx = nothing
    @struct run(; scale = something(ctx, 0)) = begin
        scaled = scale * 2
    end
    reader = (rcr_bump!(:defaulted_reader); run().scaled)
end

# A sibling child reading another child's member through its forwarded name.
@dynamicstruct struct ForwardingRoot
    ctx = nothing
    model = (rcr_bump!(:forward_model); 7)
    @struct pins = begin
        on_context = ctx
        shared = 1
    end
    @struct other = begin
        on_model = (rcr_bump!(:other_on_model); model + 1)
        on_pins = (rcr_bump!(:other_on_pins); pins.on_context)
    end
    model_reader = (rcr_bump!(:model_reader); other.on_model)
    pins_reader = (rcr_bump!(:pins_reader); other.on_pins)
end

# The shape a refit has: a member holds an object of its own, whose cached choice
# is cleared, and what derives from it is read through a helper.
@dynamicstruct struct Pin
    version::Int
    choice = (rcr_bump!(:pin_choice); get(RCR_CALLS, :pin_choice, 0) * version)
end
_rcr_epoch(pin) = pin.choice
@dynamicstruct struct PinnedRoot
    ctx = nothing
    @struct pins = begin
        ap3 = Pin(10)
    end
    model = (rcr_bump!(:pinned_model); _rcr_epoch(pins.ap3))
    evaluation = (rcr_bump!(:pinned_evaluation); model + 1)
end
end

@testitem "a sibling reading a shared member of an inline child is shared across views" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ReaderRoot()
views = [remount(source; ctx=i) for i in 1:3]
for v in views
    sync!(v)
    @test v.shown() == 84
    @test v.on_parent_reader == 11
    @test v.indexed_reader == 6
    @test v.destructured == 43
end
for name in (:model, :fit, :on_parent_reader, :indexed_reader, :destructured, :pin_shared, :pin_on_parent)
    @test RCR_CALLS[name] == 1
end
# The retained object and every view hold one value.
@test source.fit == 84
@test RCR_CALLS[:fit] == 1
for name in (:model, :fit, :on_parent_reader, :indexed_reader, :destructured)
    @test !(name in rcr_context_names(views[1]))
end
# The child instance is still each view's own.
@test views[1].pins !== views[2].pins
@test views[1].pins.__parent__ === views[1]
@test :pins in rcr_context_names(views[1])
end

@testitem "a sibling reading context through an inline child stays per view" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ReaderRoot()
for i in 1:3
    v = remount(source; ctx=i)
    @test v.context_reader == i
    @test v.through_reader == i
    @test v.forwarded_reader == i
    @test v.indexed_context_reader == (i, 3)
    @test v.destructured_context == i
    @test v.downstream == i
end
for name in (:context_reader, :through_reader, :forwarded_reader, :indexed_context_reader,
             :destructured_context, :downstream)
    @test RCR_CALLS[name] == 3
end
end

@testitem "a sibling holding the child instance keeps its own view's child" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ReaderRoot()
a = remount(source; ctx=:a)
b = remount(source; ctx=:b)
@test a.holder.__parent__ === a
@test b.holder.__parent__ === b
@test b.holder.on_context === :b
@test RCR_CALLS[:holder] == 2
end

@testitem "a context-derived index argument keeps a reader per view" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ReaderRoot()
@test [remount(source; ctx=i).argument_reader for i in 1:3] == [2, 4, 6]
@test RCR_CALLS[:argument_reader] == 3
end

@testitem "reads through nested inline children are decided at the member" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = DeepRoot()
for i in 1:3
    v = remount(source; ctx=i)
    @test v.deep_reader == 5
    @test v.deep_context_reader == i
end
@test RCR_CALLS[:deep_reader] == 1
@test RCR_CALLS[:deep] == 1
@test RCR_CALLS[:deep_context_reader] == 3
end

@testitem "what reads an opaque child member stays per view" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = OpaqueMemberRoot()
@test [remount(source; ctx=i).reader for i in 1:3] == [1, 2, 3]
@test RCR_CALLS[:opaque_reader] == 3
end

@testitem "what reads an external child is shared unless its construction reads context" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ExternalChildRoot()
views = [remount(source; ctx=i) for i in 1:3]
@test [v.reader for v in views] == [2, 2, 2]
@test RCR_CALLS[:external_reader] == 1
@test [v.scoped_reader for v in views] == [2, 3, 4]
@test RCR_CALLS[:external_scoped_reader] == 3
end

@testitem "a keyword default that is code keeps a reader per view" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = DefaultedChildRoot()
@test [remount(source; ctx=i).reader for i in 1:3] == [2, 4, 6]
@test RCR_CALLS[:defaulted_reader] == 3
end

@testitem "a child reading a sibling child's member through its forwarded name" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ForwardingRoot()
for i in 1:3
    v = remount(source; ctx=i)
    @test v.model_reader == 8
    @test v.pins_reader == i
end
# A forwarded plain property is shared all the way through.
@test RCR_CALLS[:forward_model] == 1
@test RCR_CALLS[:model_reader] == 1
@test RCR_CALLS[:other_on_model] == 1
# A forwarded child is conservatively per view, with the right value.
@test RCR_CALLS[:pins_reader] == 3
end

@testitem "sync! and clear_cache! still reach a shared sibling of an inline child" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = ReaderRoot()
v1 = remount(source; ctx=1)
sync!(v1)
@test v1.fit == 84
@test RCR_CALLS[:fit] == 1

# A request's sync with nothing changed drops nothing, however often it runs.
for i in 2:4
    v = remount(source; ctx=i)
    @test isempty(sync!(v))
    @test v.fit == 84
end
@test RCR_CALLS[:fit] == 1
@test RCR_CALLS[:model] == 1

# A child's member cleared on the retained child reaches its readers at the next
# sync, the way a refit moves a pin.
DynamicObjects.clear_cache!(source.pins, :shared)
v5 = remount(source; ctx=5)
dropped = sync!(v5)
@test :model in dropped
@test :fit in dropped
@test v5.fit == 84
@test RCR_CALLS[:pin_shared] == 2
@test RCR_CALLS[:model] == 2
@test RCR_CALLS[:fit] == 2
v6 = remount(source; ctx=6)
@test isempty(sync!(v6))
@test v6.fit == 84
@test RCR_CALLS[:fit] == 2

# A clear through a view of the child reaches them too.
DynamicObjects.clear_cache!(v6.pins, :shared)
v7 = remount(source; ctx=7)
@test :fit in sync!(v7)
@test v7.fit == 84
@test RCR_CALLS[:fit] == 3

# A clear of the reader on the retained object drops the shared value for every view.
DynamicObjects.clear_cache!(source, :model)
@test remount(source; ctx=8).fit == 84
@test RCR_CALLS[:model] == 4
@test RCR_CALLS[:fit] == 4
end

@testitem "clearing a choice held by a child's member recomputes its shared readers" setup=[RemountChildReaders] begin
using DynamicObjects

rcr_reset!()
source = PinnedRoot()
for i in 1:3
    v = remount(source; ctx=i)
    @test isempty(sync!(v))
    @test v.evaluation == 11
end
@test RCR_CALLS[:pinned_evaluation] == 1
@test RCR_CALLS[:pin_choice] == 1

# A request clears the pin through its own view of the child.
v = remount(source; ctx=4)
DynamicObjects.clear_cache!(v.pins.ap3, :choice)
after = remount(source; ctx=5)
@test :evaluation in sync!(after)
@test after.evaluation == 21
@test RCR_CALLS[:pinned_model] == 2
@test RCR_CALLS[:pinned_evaluation] == 2

# Later requests share the recomputed value, and nothing drops it again.
for i in 6:8
    w = remount(source; ctx=i)
    @test isempty(sync!(w))
    @test w.evaluation == 21
end
@test RCR_CALLS[:pinned_evaluation] == 2
end

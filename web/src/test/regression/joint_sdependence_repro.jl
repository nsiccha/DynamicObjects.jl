using DynamicObjects

# ~Bruno shape for the joint S-dependence bug.
# SAppData's `datasets` is a nested DO child that carries __parent__=appdata, so its TYPE
# embeds SAppData (the S-dependence). SCtx holds __appdata__ + a child route SFit. SFit reads
# __parent__.__appdata__.datasets, whose type embeds SAppData; when SFit is typed as SCtx's
# `fit` slot, __parent__ is the SCtx-probe -> its __appdata__ is empty -> SDatasets{SAppData{empty}}
# frozen into the slot -> runtime's real SDatasets{SAppData{real}} won't convert.

@dynamicstruct struct SDatasets
    tag::Int
    rows = tag * 100 + (isnothing(__parent__) ? 0 : __parent__.seed)
end

@dynamicstruct struct SAppData
    seed::Int
    datasets = SDatasets(seed; __parent__ = __self__)
end

@dynamicstruct struct SFit
    m::Int
    ds = __parent__.__appdata__.datasets
    result = m + ds.rows
end

@dynamicstruct struct SCtx
    cfg::Int
    __appdata__ = SAppData(cfg)
    fit = SFit(cfg; __parent__ = __self__)
end

ctx = SCtx(7)
@assert ctx.__appdata__.datasets.rows == 707 "appdata.datasets.rows = $(ctx.__appdata__.datasets.rows), expect 707"
@assert ctx.fit.ds.rows == 707 "fit.ds.rows = $(ctx.fit.ds.rows), expect 707"
@assert ctx.fit.result == 714 "fit.result = $(ctx.fit.result), expect 714"
println("SYNTHETIC OK  (707/707/714) — joint S-dependence convert freeze fixed")

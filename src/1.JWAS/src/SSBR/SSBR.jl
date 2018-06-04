function SSBRrun(mme,ped::PedModule.Pedigree,df)
    mme.ped  = deepcopy(ped)
    geno     = mme.M
    ped      = mme.ped
    Ai_nn,Ai_ng = calc_Ai(ped,geno,mme)
    impute_genotypes(geno,ped,mme,Ai_nn,Ai_ng)

    #add model terms for SSBR
    add_term(mme,"ϵ") #impuatation residual
    add_term(mme,"J") #centering
    #add data for ϵ and J
    IDs       = convert(Array,df[:,1])
    isnongeno = [ID in mme.ped.setNG for ID in IDs] #true/false
    data_ϵ    = deepcopy(df[:,1])
    data_ϵ[.!isnongeno].="0"
    df[Symbol("ϵ")]=data_ϵ

    df[Symbol("J")]=make_JVecs(mme,df,Ai_nn,Ai_ng)
    set_random(mme,"ϵ",mme.M.G,Vinv=Ai_nn,names=mme.M.obsID[1:size(Ai_nn,1)])#inv(mme.Gi) wrong here
end

############################################################################
# Phenotypes (any order )
############################################################################

############################################################################
# Pedigree
############################################################################
function calc_Ai(ped,geno,mme)
    #reorder in A (ped) as genotyped id then non-genotyped id
    num_pedn = PedModule.genoSet!(geno.obsID,ped)
    #calculate Ai, Ai_nn, Ai_ng
    mme.Ai   = PedModule.AInverse(ped)
    Ai_nn    = mme.Ai[1:num_pedn,1:num_pedn]
    Ai_ng    = mme.Ai[1:num_pedn,(num_pedn+1):size(mme.Ai,1)]
    return Ai_nn,Ai_ng
end
############################################################################
# Genotypes
############################################################################
function impute_genotypes(geno,ped,mme,Ai_nn,Ai_ng)
    Mg   = Array{Float64,2}(geno.nObs,geno.nMarkers)
    MgID = Array{String,1}(geno.nObs)
    num_pedn = size(Ai_nn,1)
    #reorder genotypes to get Mg with the same order as Ai_gg
    for i in 1:geno.nObs #Better to use Z matrix?
      id        = geno.obsID[i]
      row       = ped.idMap[id].seqID - num_pedn
      Mg[row,:] = geno.genotypes[i,:]
      MgID[row] = id
    end
    #impute genotypes for non-genotyped inds
    Mfull = [Ai_nn\(-Ai_ng*Mg);Mg];
    IDs   = PedModule.getIDs(ped) #mme.M.obsID at the end (double-check)

    mme.M.genotypes = Mfull
    mme.M.obsID     = IDs
    gc()
end
############################################################################
# Fixed effects (J)
############################################################################
function make_JVecs(mme,df,Ai_nn,Ai_ng)
    mme.obsID =  map(string,df[:,1])
    Jg = -ones(size(Ai_ng,2))
    Jn = Ai_nn\(-Ai_ng*Jg)
    J  = [Jn;
          Jg]
    Z  = mkmat_incidence_factor(mme.obsID,mme.M.obsID)#pedigree ID

    return Z*J
end

"""
add to model an extra term: imputation_residual
"""
function add_term(mme,term::AbstractString)
    for m in 1:mme.nModels
        modelterm = ModelTerm(term,m)
        push!(mme.modelTerms,modelterm)
        mme.modelTermDict[modelterm.trmStr]=modelterm
    end
end
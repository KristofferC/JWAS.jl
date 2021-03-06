################################################################################
#MCMC for RR-BLUP, BayesC, BayesCπ and "conventional (no markers).
#
#In GBLUP, pseudo markers are used.
#y = μ + a + e with mean(a)=0,var(a)=Gσ²=MM'σ² and G = LDL' <==>
#y = μ + Lα +e with mean(α)=0,var(α)=D*σ² : L orthogonal
#
#Threshold trait
#Sorensen and Gianola, Likelihood, Bayesian, and MCMC Methods in Quantitative Genetics
#Wang et al.(2013). Bayesian methods for estimating GEBVs of threshold traits.
#Heredity, 110(3), 213–219.
################################################################################
function MCMC_BayesianAlphabet(nIter,mme,df;
                     Rinv                       = false,
                     burnin                     = 0,
                     π                          = 0.0,
                     estimatePi                 = false,
                     estimateScale              = false,
                     starting_value             = false,
                     outFreq                    = 1000,
                     methods                    = "BayesC",
                     output_samples_frequency   = 0,
                     update_priors_frequency    = 0,
                     output_file                = "MCMC_samples",
                     categorical_trait          = false)

    ############################################################################
    # Categorical Traits
    ############################################################################
    if categorical_trait == true
        #starting values for thresholds  -∞ < t1=0 < t2 < ... < t_{#category-1} < +∞
        # where t1=0 (must be fixed to center the distribution) and t_{#category-1}<1.
        #Then liabilities are sampled and stored in mme.ySparse
        category_obs  = map(Int,mme.ySparse) # categories (1,2,2,3,1...)
        ncategories = length(unique(category_obs))
        #-Inf,t1,t2,...,t_{#c-1},Inf, where t1=0 and t_{#c-1}<1
        thresholds = [-Inf;range(0, length=ncategories,stop=1)[1:(end-1)];Inf]

        cmean      = mme.X*starting_value[1:size(mme.mmeLhs,1)] #maker effects defaulting to all zeros
        for i in 1:length(category_obs) #1,2,2,3,1...
            whichcategory = category_obs[i]
            mme.ySparse[i] = rand(truncated(Normal(cmean[i], 1), thresholds[whichcategory], thresholds[whichcategory+1]))
        end
    end
    ############################################################################
    # Working Variables
    # 1) samples at current iteration (starting values at the beginning, defaulting to zeros)
    # 2) posterior mean and variance at current iteration (zeros at the beginning)
    # 3) ycorr, phenotypes corrected for all effects
    ############################################################################
    #location parameters
    sol                = starting_value[1:size(mme.mmeLhs,1)]
    solMean, solMean2  = zero(sol),zero(sol)
    #residual variance
    if categorical_trait == false
        meanVare = meanVare2 = 0.0
    else
        mme.RNew = meanVare = meanVare2 = 1.0
    end
    #polygenic effects (A), e.g, Animal+ Maternal
    if mme.pedTrmVec != 0
       G0Mean,G0Mean2  = zero(mme.Gi),zero(mme.Gi)
    end
    #marker effects
    if mme.M != 0
        mGibbs                        = GibbsMats(mme.M.genotypes)
        nObs,nMarkers, M              = mGibbs.nrows,mGibbs.ncols,mGibbs.X
        mArray,mpm,mRinvArray,mpRinvm = mGibbs.xArray,mGibbs.xpx,mGibbs.xRinvArray,mGibbs.xpRinvx

        if methods=="BayesB" #α=β.*δ
            mme.M.G        = fill(mme.M.G,nMarkers) #a scalar in BayesC but a vector in BayeB
        end
        if methods=="BayesL"         #in the MTBayesLasso paper
            mme.M.G   /= 8           #mme.M.G is the scale Matrix, Sigma
            mme.M.scale /= 8
            gammaDist  = Gamma(1, 8) #8 is the scale parameter of the Gamma distribution (1/8 is the rate parameter)
            gammaArray = rand(gammaDist,nMarkers)
        end
        if methods=="GBLUP"
            mme.M.genotypes  = mme.M.genotypes ./ sqrt.(2*mme.M.alleleFreq.*(1 .- mme.M.alleleFreq))
            G       = (mme.M.genotypes*mme.M.genotypes'+ I*0.00001)/nMarkers
            eigenG  = eigen(G)
            L       = eigenG.vectors
            D       = eigenG.values
            # α is pseudo marker effects of length nobs (starting values = L'(starting value for BV)
            nMarkers= nObs

            #reset parameter in mme.M
            mme.M.G         = mme.M.genetic_variance
            mme.M.scale     = mme.M.G*(mme.df.marker-2)/mme.df.marker
            mme.M.markerID  = string.(1:nObs) #pseudo markers of length=nObs
            mme.M.genotypes = L
            #reset parameters in output
            Zo  = mkmat_incidence_factor(mme.output_ID,mme.M.obsID)
            mme.output_genotypes = (mme.output_ID == mme.M.obsID ? mme.M.genotypes : Zo*mme.M.genotypes)
            #realign pseudo genotypes to phenotypes
            Z               = mkmat_incidence_factor(mme.obsID,mme.M.obsID)
            mme.M.genotypes = Z*mme.M.genotypes
            mme.M.obsID     = mme.obsID
            mme.M.nObs      = length(mme.M.obsID)
        end
        α                            = starting_value[(size(mme.mmeLhs,1)+1):end]
        if methods == "GBLUP"
            α  = L'α
        end
        β                            = copy(α)          #partial marker effeccts used in BayesB
        δ                            = ones(typeof(α[1]),nMarkers)   #inclusion indicator for marker effects
        meanAlpha,meanAlpha2         = zero(α),zero(α)  #marker effects
        meanDelta                    = zero(δ)          #inclusion indicator
        mean_pi,mean_pi2             = 0.0,0.0          #inclusion probability
        meanVara,meanVara2           = 0.0,0.0          #marker effect variances
        meanScaleVara,meanScaleVara2 = 0.0,0.0          #scale parameter for prior of marker effect variance
    end
    #phenotypes corrected for all effects
    ycorr       = vec(Matrix(mme.ySparse)-mme.X*sol)
    if mme.M != 0 && α!=zero(α)
        ycorr = ycorr - M*α
    end
    ############################################################################
    #  SET UP OUTPUT MCMC samples
    ############################################################################
    if output_samples_frequency != 0
        outfile=output_MCMC_samples_setup(mme,nIter-burnin,output_samples_frequency,output_file)
    end
    ############################################################################
    # MCMC (starting values for sol (zeros);  mme.RNew; G0 are used)
    ############################################################################
    @showprogress "running MCMC for "*methods*"..." for iter=1:nIter

        if categorical_trait == true
            ########################################################################
            # 0. Categorical traits
            # 0.1 liabilities
            ########################################################################
            cmean = mme.ySparse - ycorr #liabilities - residuals
            for i in 1:length(category_obs) #1,2,2,3,1...
                whichcategory = category_obs[i]
                mme.ySparse[i] = rand(truncated(Normal(cmean[i], 1), thresholds[whichcategory], thresholds[whichcategory+1]))
            end
            ########################################################################
            # 0. Categorical traits
            # 0.2 Thresholds
            ########################################################################
            #thresholds -∞,t1,t2,...,t_{categories-1},+∞
            #the threshold t1=0 must be fixed to center the distribution
            for i in 3:(length(thresholds)-1) #e.g., t2 between categories 2 and 3
                lowerboundry  = maximum(mme.ySparse[category_obs .== (i-1)])
                upperboundry  = minimum(mme.ySparse[category_obs .== i])
                thresholds[i] = rand(Uniform(lowerboundry,upperboundry))
            end
            ycorr = mme.ySparse - cmean
        end
        ########################################################################
        # 1.1. Non-Marker Location Parameters
        ########################################################################
        ycorr = ycorr + mme.X*sol
        if Rinv == false
            rhs = mme.X'ycorr
        else
            rhs = mme.X'Diagonal(Rinv)*ycorr
        end

        Gibbs(mme.mmeLhs,sol,rhs,mme.RNew)

        ycorr = ycorr - mme.X*sol
        ########################################################################
        # 1.2 Marker Effects
        ########################################################################
        if mme.M !=0
            if methods in ["BayesC","BayesB","BayesA"]
                locus_effect_variances = (methods=="BayesC" ? fill(mme.M.G,nMarkers) : mme.M.G)
                nLoci = BayesABC!(mArray,mpm,mRinvArray,mpRinvm,ycorr,α,β,δ,mme.RNew,locus_effect_variances,π)
            elseif methods=="RR-BLUP"
                BayesC0!(mArray,mpm,mRinvArray,mpRinvm,ycorr,α,mme.RNew,mme.M.G)
                nLoci = nMarkers
            elseif methods == "BayesL"
                BayesL!(mArray,mpm,mRinvArray,mpRinvm,ycorr,α,gammaArray,mme.RNew,mme.M.G)
                nLoci = nMarkers
            elseif methods == "GBLUP"
                ycorr = ycorr + mme.M.genotypes*α
                lhs   = 1 .+ mme.RNew./(mme.M.G*D)
                mean1 = mme.M.genotypes'ycorr./lhs
                α     = mean1 + randn(nObs).*sqrt.(mme.RNew./lhs)
                ycorr = ycorr - mme.M.genotypes*α
            end
            #sample Pi
            if estimatePi == true
                π = samplePi(nLoci, nMarkers)
            end
        end
        ########################################################################
        # 2.1 Genetic Covariance Matrix (Polygenic Effects) (variance.jl)
        # 2.2 varainces for (iid) random effects;not required(empty)=>jump out
        ########################################################################
        sampleVCs(mme,sol)
        addVinv(mme)
        ########################################################################
        # 2.3 Residual Variance
        ########################################################################
        if categorical_trait == false
            mme.ROld = mme.RNew
            mme.RNew = sample_variance(ycorr.* (Rinv!=false ? sqrt.(Rinv) : 1.0), length(ycorr), mme.df.residual, mme.scaleRes)
        end
        ########################################################################
        # 2.4 Marker Effects Variance
        ########################################################################
        if mme.M != 0 && mme.MCMCinfo.estimate_variance
            if methods in ["BayesC","RR-BLUP"]
                mme.M.G  = sample_variance(α, nLoci, mme.df.marker, mme.M.scale)
            elseif methods == "BayesB"
                for j=1:nMarkers
                    mme.M.G[j] = sample_variance(β[j],1,mme.df.marker, mme.M.scale)
                end
            elseif methods == "BayesL"
                ssq = 0.0
                for i=1:size(α,1)
                    ssq += α[i]^2/gammaArray[i]
                end
                mme.M.G = (ssq + mme.df.marker*mme.M.scale)/rand(Chisq(nLoci+mme.df.marker))
               # MH sampler of gammaArray (Appendix C in paper)
                sampleGammaArray!(gammaArray,α,mme.M.G)
            elseif methods == "GBLUP"
                mme.M.G  = sample_variance(α./sqrt.(D), nObs,mme.df.marker, mme.M.scale)
            else
                error("Sampling of marker effect variances is not available")
            end
        end
        ########################################################################
        # 2.5 Update priors using posteriors (empirical)
        ########################################################################
        if update_priors_frequency !=0 && iter%update_priors_frequency==0
            if mme.M!=0 && methods != "BayesB"
                mme.M.scale   = meanVara*(mme.df.marker-2)/mme.df.marker
            end
            if mme.pedTrmVec != 0
                mme.scalePed  = G0Mean*(mme.df.polygenic - size(mme.pedTrmVec,1) - 1)
            end
            mme.scaleRes  =  meanVare*(mme.df.residual-2)/mme.df.residual
            println("\n Update priors from posteriors.")
        end
        ########################################################################
        # 2.6 sample Scale parameter in prior for marker effect variances
        ########################################################################
        if estimateScale == true
            a = size(mme.M.G,1)*mme.df.marker/2   + 1
            b = sum(mme.df.marker ./ (2*mme.M.G )) + 1
            mme.M.scale = rand(Gamma(a,1/b))
        end
        ########################################################################
        # 3.1 Save MCMC samples
        ########################################################################
        if iter>burnin && (iter-burnin)%output_samples_frequency == 0
            if mme.M != 0
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),π,α,mme.M.G,outfile)
            else
                output_MCMC_samples(mme,sol,mme.RNew,(mme.pedTrmVec!=0 ? inv(mme.Gi) : false),false,false,false,outfile)
            end

            nsamples = (iter-burnin)/output_samples_frequency
            solMean   += (sol - solMean)/nsamples
            solMean2  += (sol .^2 - solMean2)/nsamples
            meanVare  += (mme.RNew - meanVare)/nsamples
            meanVare2 += (mme.RNew .^2 - meanVare2)/nsamples

            if mme.pedTrmVec != 0
                G0Mean  += (inv(mme.Gi)  - G0Mean )/nsamples
                G0Mean2 += (inv(mme.Gi) .^2  - G0Mean2 )/nsamples
            end
            if mme.M != 0
                meanAlpha  += (α - meanAlpha)/nsamples
                meanAlpha2 += (α .^2 - meanAlpha2)/nsamples
                meanDelta  += (δ - meanDelta)/nsamples

                if estimatePi == true
                    mean_pi += (π-mean_pi)/nsamples
                    mean_pi2 += (π .^2-mean_pi2)/nsamples
                end
                if methods != "BayesB"
                    meanVara += (mme.M.G - meanVara)/nsamples
                    meanVara2 += (mme.M.G .^2 - meanVara2)/nsamples
                end
                if estimateScale == true
                    meanScaleVara += (mme.M.scale - meanScaleVara)/nsamples
                    meanScaleVara2 += (mme.M.scale .^2 - meanScaleVara2)/nsamples
                end
            end
        end

        ########################################################################
        # 3.2 Printout
        ########################################################################
        if iter%outFreq==0 && iter>burnin
            println("\nPosterior means at iteration: ",iter)
            println("Residual variance: ",round(meanVare,digits=6))
        end
    end

    ############################################################################
    # After MCMC
    ############################################################################
    if output_samples_frequency != 0
      for (key,value) in outfile
        close(value)
      end
    end
    if methods == "GBLUP"
        mv(output_file*"_marker_effects_variances.txt",output_file*"_genetic_variance(REML).txt")
    end
    output=output_result(mme,output_file,
                         solMean,meanVare,
                         mme.pedTrmVec!=0 ? G0Mean : false,
                         mme.M != 0 ? meanAlpha : false,
                         mme.M != 0 ? meanDelta : false,
                         mme.M != 0 ? meanVara : false,
                         mme.M != 0 ? estimatePi : false,
                         mme.M != 0 ? mean_pi : false,
                         mme.M != 0 ? estimateScale : false,
                         mme.M != 0 ? meanScaleVara : false,
                         solMean2,meanVare2,
                         mme.pedTrmVec!=0 ? G0Mean2 : false,
                         mme.M != 0 ? meanAlpha2 : false,
                         mme.M != 0 ? meanVara2 : false,
                         mme.M != 0 ? mean_pi2 : false,
                         mme.M != 0 ? meanScaleVara2 : false)
    return output
end

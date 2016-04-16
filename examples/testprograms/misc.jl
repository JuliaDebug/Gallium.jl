@noinline function sinthesin(x)
    sin(sin(x))
end

@noinline function inaloop(y)
    for i = 1:y
	sinthesin(i)
    end
end

type averymutabletype
    a::Int
end

@noinline sinthesin(a::averymutabletype) = sinthesin(a.a)

function testforline(branch)
    a = gcd(4, 25)
    if branch
        b = gcd(7, 21)
    else
        b = gcd(6, 24)
    end
    gcd(a, b)
end
